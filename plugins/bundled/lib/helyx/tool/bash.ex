defmodule Helyx.Tool.Bash do
  @keep_bytes 4 * Helyx.Tool.max_bytes()

  @moduledoc """
  Runs a shell command in the working directory with `bash -c`.

  stdout and stderr are merged. Long output is cut from the head end and the
  result says which lines it shows. Only the last #{@keep_bytes} bytes are
  kept while the command runs, so a command that never stops writing does
  not grow the buffer; the result then says so, and its line count is of
  the kept part. A non-zero exit code is reported in the text; the result
  is an error only when the command could not start. stdin is `/dev/null`.
  The call returns when stdout closes, so a background child that keeps
  stdout open holds the call until it exits.

  The command runs in its own process group under a perl watchdog. The
  watchdog registers the group with the hands before the command is allowed
  to execute, and ties the command's life to the port: when the port closes,
  because anything above the command died, the watchdog kills the group.
  perl is required; `check/0` reports a system without it when the hands
  start.
  """

  @behaviour Helyx.Tool

  # The watchdog forks the command into its own process group and stays in
  # the launcher's own group, so the port's OS process is the watchdog. It
  # writes the command's group id as the stdout marker and holds the command
  # until the go-ahead line arrives on stdin, so either the hands hold the
  # group id before the command runs, or the command never ran. Then it
  # watches: when its stdin ends, because the port closed, it TERMs the
  # group, waits the grace period, KILLs it, and reaps the command before it
  # exits; when the command ends first, it exits with the command's status
  # (128 plus the signal for a signal death). The watchdog ignores TERM in
  # the parent only, after the fork, so the hands can TERM every registered
  # group without cutting the cleanup short; ignored dispositions survive
  # exec, so the child must not inherit one. The 50 ms select tick is the
  # poll for both stdin and the child.
  #
  # The watchdog enters the working directory itself, before the fork. The
  # port's cd option has no failure signal: the emulator's child exits with
  # status 2, which a real command can also do. A chdir, pipe, or fork that
  # fails writes the marker with `0`, which is never a group id, then the
  # reason, and no command exists.
  #
  # A marker line is "<nonce> <number>". The nonce is random for each call
  # and reaches the watchdog in its arguments only. The command is held
  # until the go-ahead, so no command output can come before the marker.
  # perl's own startup output can, because stderr is merged: a bad locale
  # warning prints environment values, which can hold any line. It cannot
  # hold the nonce, so no text can pass for a marker; `read_marker/4` reads
  # past the rest.
  #
  # The start report (#70). The held child writes the start line,
  # "<nonce> 1", as its last act before the `exec`, so the line is in front
  # of all command output, and a result is ok only with it: a watchdog that
  # dies before it passes the go-ahead on, or a child that dies while held,
  # leaves no start line. The child reports a failed `exec`, or its own
  # death by `die`, through a second pipe that closes on `exec` (perl sets
  # close-on-exec on every descriptor above 2): the watchdog reads end of
  # file when the `exec` worked, and the error when it did not. It reads
  # the pipe only after the child ended, so the read never waits: the write
  # end is closed by then, by the `exec` or by the exit, and the watchdog's
  # poll of stdin is never held. It then writes "<go> 0" and the error.
  # `<go>` is a second random word, which arrives on stdin as the go-ahead
  # line, after the fork: it is in no argument list and not in the child, so
  # a command that ran cannot write a failure report, and the report counts
  # wherever it is in the output: perl's own text can come before it (with
  # `PERL5OPT=-w`, a warning about the `exec`). The command can read the
  # nonce from the process table, but a start line is only true of a command
  # that ran. The pipe is binary, so `PERL_UNICODE` cannot make its reads
  # and writes fail.
  #
  # perl code that the user's environment loads into the watchdog (PERL5LIB,
  # PERL5OPT) can read the nonce; that is the user's own code and out of
  # scope.
  @watchdog ~S"""
  use POSIX ":sys_wait_h";
  my $nonce = shift @ARGV;
  sub fail { syswrite(STDOUT, "$nonce 0\n$_[0]: $!"); exit 0 }
  my $dir = shift @ARGV;
  chdir($dir) or fail("cannot enter the working directory $dir");
  pipe(my $r, my $w) or fail("pipe failed");
  pipe(my $er, my $ew) or fail("report pipe failed");
  binmode($er); binmode($ew);
  my $child = fork() // fail("fork failed");
  if ($child == 0) {
    close($w); close($er);
    setpgrp(0, 0);
    eval {
      sysread($r, my $go, 1) or exit 0;
      open(STDIN, "<", "/dev/null");
      syswrite(STDOUT, "$nonce 1\n");
      exec @ARGV;
      die "cannot run $ARGV[0]: $!\n";
    };
    syswrite($ew, $@);
    exit 0;
  }
  $SIG{TERM} = "IGNORE";
  close($r); close($ew);
  syswrite(STDOUT, "$nonce $child\n");
  my $go = readline(STDIN);
  if (defined($go)) { syswrite($w, "g"); close($w) }
  else { close($w); kill("KILL", -$child); waitpid($child, 0); exit 0 }
  chomp($go);
  while (1) {
    my $rin = ""; vec($rin, fileno(STDIN), 1) = 1;
    my $n = select(my $rout = $rin, undef, undef, 0.05);
    if ($n and sysread(STDIN, my $buf, 4096) == 0) {
      kill("TERM", -$child);
      my $t = 0;
      while (waitpid($child, WNOHANG) == 0 and $t < 0.5) { select(undef, undef, undef, 0.05); $t += 0.05 }
      kill("KILL", -$child);
      waitpid($child, 0);
      exit 0;
    }
    if (waitpid($child, WNOHANG) > 0) {
      my $s = $?;
      if (sysread($er, my $err, 4096)) { syswrite(STDOUT, "$go 0\n$err"); exit 0 }
      exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
    }
  }
  """

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run a shell command in the working directory. Returns stdout and stderr, " <>
      "the last 2000 lines or 50 KB, and the exit code when it is not zero."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{"command" => %{"type" => "string"}},
      "required" => ["command"]
    }
  end

  # Recorded risk: a future macOS may ship without perl. The watchdog is
  # small enough to rewrite in sh with job control if that happens.
  @impl true
  def check, do: check(&System.find_executable/1)

  @doc false
  def check(find) do
    if find.("perl") do
      :ok
    else
      {:error, "perl not found: the bash tool needs perl to watch its commands"}
    end
  end

  # Port arguments are NUL-terminated C strings: a string with a NUL would
  # be cut there silently and the result would report success for something
  # that did not run as given. JSON strings can carry an escaped NUL, so the
  # model can send one. Every string that reaches the port is checked here.
  @impl true
  def run(%{"command" => command}, cwd) when is_binary(command) do
    cond do
      String.contains?(command, <<0>>) ->
        {:error, "the command contains a NUL byte"}

      String.contains?(cwd, <<0>>) ->
        {:error, "the working directory contains a NUL byte"}

      true ->
        run_command(command, cwd)
    end
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  defp run_command(command, cwd) do
    nonce = random_word()
    {exe, args} = launcher(command, cwd, nonce)

    # No cd option: the watchdog enters `cwd`, so a failure has a signal.
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    # The runtime detaches port programs into their own process group, so
    # the port's OS pid is the watchdog's group. Registered as :watchdog:
    # the hands wait for it, so an abort cannot return while the command is
    # a zombie, and they sweep it only after the command group is gone, so
    # a KILL from the hands can never cut the reap short.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> Helyx.Tool.register_group(os_pid, :watchdog)
      nil -> :ok
    end

    case consume(port, nonce) do
      {:not_started, reason} ->
        {:error, "the command did not start: " <> Helyx.Tool.truncate(reason, :tail)}

      {output, dropped?, status} ->
        {:ok, render(output, dropped?, status)}
    end
  end

  @doc false
  # Public for the watchdog's direct tests.
  def launcher(command, cwd, nonce) do
    bash = System.find_executable("bash") || "/bin/bash"
    perl = System.find_executable("perl") || "/usr/bin/perl"
    {perl, ["-e", @watchdog, "--", nonce, cwd, bash, "-c", command]}
  end

  # Takes the marker off the stream. Only a group marker leads to the
  # go-ahead, after the group is registered: a command never runs without
  # its group in the hands, and there is no ok result without a group marker.
  # With no marker, the closed port is the watchdog's signal to kill the
  # child it holds, if it got that far.
  defp consume(port, nonce) do
    case read_marker(port, nonce, "", "") do
      {:not_started, acc} ->
        {reason, _dropped?, _status} = collect(port, acc, false)
        {:not_started, reason}

      {:no_marker, text} ->
        close(port)
        {:not_started, "the watchdog gave no marker: " <> text}

      {group, pre} ->
        Helyx.Tool.register_group(group)
        go = random_word()
        go_ahead(port, go)
        start_report(collect(port, pre, false), pre, nonce <> " 1\n", go <> " 0\n")
    end
  end

  # Reads the start report off the collected output (see the watchdog).
  # `pre` is what came before the group marker, perl's own startup output.
  # Output that was cut has lost its head, and only a command that ran
  # writes that much: the watchdog's own text is at most `pre`, the start
  # line, perl's warnings, and a 4,096-byte report.
  defp start_report({_output, true, _status} = ran, _pre, _start, _failed), do: ran

  defp start_report({output, false, status}, pre, start, failed) do
    ^pre <> rest = output

    case String.split(rest, failed, parts: 2) do
      [before, reason] ->
        {:not_started, pre <> String.replace_prefix(before, start, "") <> reason}

      [^start <> body] ->
        {pre <> body, false, status}

      [_no_start_line] ->
        {:not_started, "the command gave no start line: " <> output}
    end
  end

  defp random_word, do: Base.encode16(:crypto.strong_rand_bytes(8))

  # A port whose watchdog already died is closed and the write raises; the
  # exit status is still in the mailbox for the collect.
  defp go_ahead(port, go) do
    Port.command(port, go <> "\n")
  rescue
    ArgumentError -> false
  end

  # The same for a close: after an exit the port is already closed.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> false
  end

  defp render(output, dropped?, status) do
    text =
      case output do
        "" -> "(no output)"
        out -> Helyx.Tool.truncate(out, :tail)
      end

    text =
      if dropped?,
        do: "[output cut: only the last #{@keep_bytes} bytes were kept]\n" <> text,
        else: text

    if status == 0, do: text, else: text <> "\nExit code: #{status}"
  end

  # ponytail: no per-call timeout; a command that never exits holds the call
  # until the turn is aborted.
  defp collect(port, acc, dropped?) do
    receive do
      {^port, {:data, data}} ->
        {acc, cut?} = keep_tail(acc <> data)
        collect(port, acc, dropped? or cut?)

      {^port, {:exit_status, status}} ->
        {acc, dropped?, status}
    end
  end

  # A character has at most three continuation bytes (`10xxxxxx`).
  @max_continuation_bytes 3

  # Cuts at twice the cap so the copy is amortised, not once per chunk.
  # The cut can land inside a character; the rest of that character is
  # dropped, so the kept tail starts on a character boundary. Only the start
  # is cleaned: the end of `acc` can hold a character the next chunk completes.
  @doc false
  # Public for the direct test of the cut.
  def keep_tail(acc) when byte_size(acc) <= 2 * @keep_bytes, do: {acc, false}

  def keep_tail(acc) do
    tail = binary_part(acc, byte_size(acc) - @keep_bytes, @keep_bytes)
    {drop_continuation(tail, @max_continuation_bytes), true}
  end

  defp drop_continuation(<<2::2, _::6, rest::binary>>, n) when n > 0,
    do: drop_continuation(rest, n - 1)

  defp drop_continuation(bin, _n), do: bin

  # The marker line must end within this many bytes of the stream. Lines
  # that perl itself may write before it take the room; a locale warning is
  # about 400 bytes.
  @max_preamble_bytes 4096

  # Finds the marker line (see the watchdog). Lines that are not a marker
  # are read past, within `@max_preamble_bytes`, and kept in front of the
  # output. The marker exists however fast the command exited, because the
  # watchdog writes it before the command may run. Returns the group
  # (or `:not_started`, see the watchdog) and the output so far. A stream
  # that ends, or reaches the limit, with no marker is `:no_marker` with its
  # text: perl did not get as far as the watchdog, or wrote too much. Only
  # a line that ends within the limit counts, marker or not, so which
  # marker is found, if any, does not depend on how the stream is cut into
  # messages. The `:no_marker` text is what had arrived by then.
  @doc false
  # Public for the direct test of the preamble limit.
  def read_marker(port, nonce, pre, acc) do
    case String.split(acc, "\n", parts: 2) do
      [line, rest] when byte_size(pre) + byte_size(line) < @max_preamble_bytes ->
        case parse_marker(line, nonce) do
          nil -> read_marker(port, nonce, pre <> line <> "\n", rest)
          marker -> {marker, pre <> rest}
        end

      [_] when byte_size(pre) + byte_size(acc) < @max_preamble_bytes ->
        receive do
          {^port, {:data, data}} -> read_marker(port, nonce, pre, acc <> data)
          {^port, {:exit_status, _status}} -> {:no_marker, pre <> acc}
        end

      _ ->
        {:no_marker, pre <> acc}
    end
  end

  # `kill -- -1` would signal every process the user may signal, so nothing
  # below 2 is ever accepted as a group. 0 is the watchdog's word for a
  # command it could not start.
  defp parse_marker(line, nonce) do
    with [^nonce, number] <- String.split(line, " "),
         {number, ""} <- Integer.parse(number) do
      case number do
        0 -> :not_started
        group when group > 1 -> group
        _ -> nil
      end
    else
      _ -> nil
    end
  end
end
