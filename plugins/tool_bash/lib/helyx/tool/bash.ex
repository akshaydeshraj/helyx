defmodule Helyx.Tool.Bash do
  @moduledoc """
  Runs a shell command in the working directory with `bash -c`.

  stdout and stderr are merged. Long output is cut from the head end and the
  result says which lines it shows. A non-zero exit code is reported in the
  text; the result is an error only when the command could not start. The
  command runs in its own process group so a later ticket can kill it as a
  group. stdin is `/dev/null`. The call returns when stdout closes, so a
  background child that keeps stdout open holds the call until it exits.
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

    {output, status} = collect(port, [])

    text =
      case IO.iodata_to_binary(output) do
        "" -> "(no output)"
        out -> Helyx.Tool.truncate(out, :tail)
      end

    {:ok, if(status == 0, do: text, else: text <> "\nExit code: #{status}")}
  end

  def run(_args, _cwd), do: {:error, "bash needs a command"}

  # ponytail: the buffer is unbounded until the abort ticket adds a timeout;
  # then cap it to a few multiples of the tail limit.
  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc | data])
      {^port, {:exit_status, status}} -> {acc, status}
    end
  end

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
