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
  @watchdog ~S"""
  use POSIX ":sys_wait_h";
  pipe(my $r, my $w) or exit 91;
  my $child = fork() // exit 91;
  if ($child == 0) {
    close($w);
    setpgrp(0, 0);
    sysread($r, my $go, 1) or exit 0;
    open(STDIN, "<", "/dev/null");
    exec @ARGV;
    exit 127;
  }
  $SIG{TERM} = "IGNORE";
  close($r);
  syswrite(STDOUT, "$child\n");
  if (defined(readline(STDIN))) { syswrite($w, "g"); close($w) }
  else { close($w); kill("KILL", -$child); waitpid($child, 0); exit 0 }
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

  # Port arguments and the cd option are NUL-terminated C strings: a string
  # with a NUL would be cut there silently and the result would report
  # success for something that did not run as given. JSON strings can carry
  # an escaped NUL, so the model can send one. Every string that reaches the
  # port is checked here.
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
    {exe, args} = launcher(command)

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cwd},
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

    {output, dropped?, status} = consume(port)

    {:ok, render(output, dropped?, status)}
  end

  @doc false
  # Public for the watchdog's direct tests.
  def launcher(command) do
    bash = System.find_executable("bash") || "/bin/bash"
    perl = System.find_executable("perl") || "/usr/bin/perl"
    {perl, ["-e", @watchdog, "--", bash, "-c", command]}
  end

  # Takes the group marker off the stream, registers the group, sends the
  # go-ahead, then collects the output. The stream can end inside the marker
  # read when the watchdog dies at once.
  defp consume(port) do
    {group, next} = read_marker(port, "")

    if group, do: Helyx.Tool.register_group(group)
    if match?({:more, _}, next), do: go_ahead(port)

    case next do
      {:more, acc} -> collect(port, acc, false)
      {:exit, acc, status} -> {acc, false, status}
    end
  end

  # A port whose watchdog already died is closed and the write raises; the
  # exit status is still in the mailbox for the collect.
  defp go_ahead(port) do
    Port.command(port, "\n")
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

  # The watchdog writes "<pgid>\n" as the first stdout bytes, before the
  # command runs, so the marker exists however fast the command exited and
  # command output can never precede it. Reads the marker off the stream and
  # returns the group and the leftover output, or the exit if the stream
  # ended first. A stream that starts with anything else is kept as output.
  defp read_marker(port, acc) do
    case String.split(acc, "\n", parts: 2) do
      [line, rest] ->
        case parse_group(line) do
          nil -> {nil, {:more, acc}}
          group -> {group, {:more, rest}}
        end

      [_] when byte_size(acc) < 32 ->
        receive do
          {^port, {:data, data}} -> read_marker(port, acc <> data)
          {^port, {:exit_status, status}} -> {nil, {:exit, acc, status}}
        end

      [_] ->
        {nil, {:more, acc}}
    end
  end

  # `kill -- -1` would signal every process the user may signal, so nothing
  # below 2 is ever accepted as a group.
  defp parse_group(line) do
    case Integer.parse(line) do
      {group, ""} when group > 1 -> group
      _ -> nil
    end
  end
end
