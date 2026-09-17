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
  its own process group so a later ticket can kill it as a group. stdin is
  `/dev/null`. The call returns when stdout closes, so a background child
  that keeps stdout open holds the call until it exits.
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
    {exe, args} = launcher(command)

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cwd},
        {:args, args}
      ])

    {output, dropped?, status} = collect(port, "", false)

    text =
      case output do
        "" -> "(no output)"
        out -> Helyx.Tool.truncate(out, :tail)
      end

    text =
      if dropped?,
        do: "[output cut: only the last #{@keep_bytes} bytes were kept]\n" <> text,
        else: text

    {:ok, if(status == 0, do: text, else: text <> "\nExit code: #{status}")}
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  # ponytail: no timeout until the abort ticket; a command that never exits
  # holds the call.
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

  # perl puts the command in its own process group and execs bash in place,
  # so the port's OS pid is the group leader. Without perl the command runs
  # in the node's group.
  # ponytail: a NIF or setsid(1) when a target has no perl.
  defp launcher(command) do
    bash = System.find_executable("bash") || "/bin/bash"
    setpgrp = ~S|setpgrp(0, 0); open(STDIN, "<", "/dev/null"); exec @ARGV|

    case System.find_executable("perl") do
      nil -> {bash, ["-c", command]}
      perl -> {perl, ["-e", setpgrp, "--", bash, "-c", command]}
    end
  end
end
