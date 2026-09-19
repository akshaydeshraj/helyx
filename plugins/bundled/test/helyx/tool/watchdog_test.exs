defmodule Helyx.Tool.Bash.WatchdogTest do
  # Direct tests of the perl watchdog through the launcher, without the
  # hands: the marker and go-ahead protocol, the status passthrough, and the
  # kill on a closed port.
  use ExUnit.Case, async: true

  import Helyx.Tool.Bash.OSHelpers

  defp open(command, bash \\ nil) do
    {exe, args} = Helyx.Tool.Bash.launcher(command, File.cwd!(), "nonce")
    args = if bash, do: List.replace_at(args, 5, bash), else: args

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
        ["nonce " <> group, rest] = String.split(data, "\n", parts: 2)
        {String.to_integer(group), rest}
    after
      2_000 -> flunk("no group marker")
    end
  end

  # Gives the go-ahead and reads up to `text`, which starts with the start
  # line. Returns what came after it.
  defp go(port, acc, text \\ "nonce 1\n") do
    true = Port.command(port, "go\n")
    await(port, acc, text)
  end

  defp await(port, acc, text) do
    case String.split(acc, text, parts: 2) do
      ["", rest] ->
        rest

      _ ->
        receive do
          {^port, {:data, data}} -> await(port, acc <> data, text)
        after
          2_000 -> flunk("no #{inspect(text)}; got #{inspect(acc)}")
        end
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
    assert {"out\nerr\n", 3} = collect(port, go(port, rest))
  end

  test "a signal death is reported as 128 plus the signal" do
    port = open("kill -TERM $$")
    {_group, rest} = read_marker(port)
    assert {_out, 143} = collect(port, go(port, rest))
  end

  test "stdin ends first: the group is killed" do
    port = open("echo ready; sleep 30")
    {group, ""} = read_marker(port)
    assert "" = go(port, "", "nonce 1\nready\n")

    Port.close(port)
    assert group_gone_within?(group, 200)
  end

  test "a command that ignores TERM is killed after the grace period" do
    port = open("trap '' TERM; echo ready; sleep 30")
    {group, ""} = read_marker(port)
    assert "" = go(port, "", "nonce 1\nready\n")

    Port.close(port)
    assert group_gone_within?(group, 300)
  end

  test "a failed exec: the start line, then the report under the go-ahead word (issue #70)" do
    port = open("echo ran", "/nonexistent/bash")
    {_group, rest} = read_marker(port)

    assert {"cannot run /nonexistent/bash: No such file or directory\n", 0} =
             collect(port, go(port, rest, "nonce 1\ngo 0\n"))
  end

  test "a held child that is stopped does not hold the kill on a closed port (issue #70)" do
    port = open("echo ran")
    {group, ""} = read_marker(port)
    {_, 0} = System.cmd("kill", ["-STOP", "-#{group}"])
    true = Port.command(port, "go\n")

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
