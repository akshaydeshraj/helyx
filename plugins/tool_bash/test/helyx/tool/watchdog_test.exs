defmodule Helyx.Tool.Bash.WatchdogTest do
  # Direct tests of the perl watchdog through the launcher, without the
  # hands: the marker and go-ahead protocol, the status passthrough, and the
  # kill on a closed port.
  use ExUnit.Case, async: true

  import Helyx.Tool.Bash.OSHelpers

  defp open(command) do
    {exe, args} = Helyx.Tool.Bash.launcher(command)

    Port.open({:spawn_executable, exe}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, args}
    ])
  end

  defp read_marker(port) do
    receive do
      {^port, {:data, data}} ->
        [line, rest] = String.split(data, "\n", parts: 2)
        {String.to_integer(line), rest}
    after
      2_000 -> flunk("no group marker")
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      5_000 -> flunk("no exit status; got #{inspect(acc)}")
    end
  end

  test "the command ends first: output and exit status pass through" do
    port = open("echo out; echo err >&2; exit 3")
    {group, rest} = read_marker(port)
    assert group > 1
    true = Port.command(port, "\n")
    assert {"out\nerr\n", 3} = collect(port, rest)
  end

  test "a signal death is reported as 128 plus the signal" do
    port = open("kill -TERM $$")
    {_group, rest} = read_marker(port)
    true = Port.command(port, "\n")
    assert {_out, 143} = collect(port, rest)
  end

  test "stdin ends first: the group is killed" do
    port = open("echo ready; sleep 30")
    {group, ""} = read_marker(port)
    true = Port.command(port, "\n")
    assert_receive {^port, {:data, "ready\n"}}, 2_000

    Port.close(port)
    assert group_gone_within?(group, 200)
  end

  test "a command that ignores TERM is killed after the grace period" do
    port = open("trap '' TERM; echo ready; sleep 30")
    {group, ""} = read_marker(port)
    true = Port.command(port, "\n")
    assert_receive {^port, {:data, "ready\n"}}, 2_000

    Port.close(port)
    assert group_gone_within?(group, 300)
  end

  @tag :tmp_dir
  test "without the go-ahead the command never runs", %{tmp_dir: dir} do
    ran = Path.join(dir, "ran")
    port = open("touch #{ran}")
    {group, ""} = read_marker(port)

    Port.close(port)
    assert group_gone_within?(group, 200)
    refute File.exists?(ran)
  end
end
