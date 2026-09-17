defmodule Helyx.Tool.Bash do
  @keep_bytes 4 * Helyx.Tool.max_bytes()

  @moduledoc """
  Runs a shell command in the working directory with `bash -c`.

  stdout and stderr are merged. Long output is cut from the head end and the
  result says which lines it shows. Only the last #{@keep_bytes} bytes are
  kept while the command runs, so a command that never stops writing does
  not grow the buffer; the result then says so, and its line count is of
  the kept part. A non-zero exit code is reported in the text; the result
  is an error only when the command could not start. The command runs in
  its own process group, registered with the hands before the command is
  allowed to execute; the hands kill the group when the call delivers or
  the turn is aborted. No process survives its call: either the hands hold
  the group, or the command never ran. stdin is `/dev/null`. The call
  returns when stdout closes, so a background child that keeps stdout open
  holds the call until it exits.
  """

  @behaviour Helyx.Tool

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

  @impl true
  def run(%{"command" => command}, cwd) when is_binary(command) do
    {exe, args, mode} = launcher(command)

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cwd},
        {:args, args}
      ])

    # Best effort for the perl-less launcher; nil when the command exits
    # before the lookup.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    {output, dropped?, status} = consume(port, mode, os_pid)

    {:ok, render(output, dropped?, status)}
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  # Takes the group marker off the stream, registers the group, sends the
  # go-ahead, then collects the output. The launcher holds the command until
  # the go-ahead, so either the hands hold the group id before the command
  # runs, or the command never ran: no abort timing can lose a process. The
  # stream can end inside the marker read when the launcher dies at once.
  defp consume(port, mode, os_pid) do
    {group, next} =
      case mode do
        :marker -> read_marker(port, "")
        :bare -> {nil, {:more, ""}}
      end

    release(port, mode, group || os_pid, next)

    case next do
      {:more, acc} -> collect(port, acc, false)
      {:exit, acc, status} -> {acc, false, status}
    end
  end

  # Registers the group with the hands, then sends the go-ahead that lets
  # the launcher exec the command. No go-ahead when the launcher already
  # died: its exit is in `next`.
  defp release(port, mode, leader, next) do
    if leader, do: Helyx.Tool.register_group(leader)
    if mode == :marker and match?({:more, _}, next), do: go_ahead(port)
    :ok
  end

  # A port whose launcher already died is closed and the write raises; the
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

  # Cuts at twice the cap so the copy is amortised, not once per chunk.
  defp keep_tail(acc) when byte_size(acc) <= 2 * @keep_bytes, do: {acc, false}
  defp keep_tail(acc), do: {binary_part(acc, byte_size(acc) - @keep_bytes, @keep_bytes), true}

  # The launcher writes "<pgid>\n" as the first stdout bytes, before the
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

  # perl puts the command in its own process group, writes the group id as
  # the stdout marker, and holds the command until the go-ahead line arrives
  # on stdin, so the command cannot run before the group is registered with
  # the hands. A Task killed before the go-ahead closes the port, perl reads
  # end of file and exits without running the command. Then perl opens stdin
  # on /dev/null and execs bash in place, so the port's OS pid is the group
  # leader. The runtime detaches port programs, so the command leads its own
  # group even without perl.
  # ponytail: without perl there is no handshake and stdin stays the port
  # pipe, so a command that reads it holds the call until the turn is
  # aborted.
  defp launcher(command) do
    bash = System.find_executable("bash") || "/bin/bash"

    setpgrp =
      ~S|setpgrp(0, 0); syswrite(STDOUT, "$$\n"); | <>
        ~S|defined(readline(STDIN)) or exit 0; | <>
        ~S|open(STDIN, "<", "/dev/null"); exec @ARGV|

    case System.find_executable("perl") do
      nil -> {bash, ["-c", command], :bare}
      perl -> {perl, ["-e", setpgrp, "--", bash, "-c", command], :marker}
    end
  end
end
