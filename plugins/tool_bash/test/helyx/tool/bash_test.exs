defmodule Helyx.Tool.BashTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Bash]})

    %{
      core: core,
      run: fn args ->
        Fake.run_tool(core, %ToolCall{id: "c", name: "bash", arguments: args}, dir)
      end
    }
  end

  # Starts a session whose one turn runs `command`, and returns the session
  # once the command is running.
  defp start_command(core, dir, command) do
    call = %ToolCall{id: "c", name: "bash", arguments: %{"command" => command}}
    :ok = Helyx.Provider.Fake.script(core, "abort", [[call]])
    {:ok, session} = Helyx.Session.start(core, model: "fake/abort", cwd: dir)
    :ok = Helyx.Session.subscribe(session)
    :ok = Helyx.Session.prompt(session, "go")
    assert_receive {:helyx_event, %Helyx.Event{type: :tool_execution_start}}, 1_000
    session
  end

  # Polls until the command has written its pid to `path`.
  defp wait_for_pid(path, tries \\ 200) do
    with {:ok, content} <- File.read(path),
         [pid] <- Regex.run(~r/^\d+$/m, content) do
      pid
    else
      _ when tries > 0 ->
        Process.sleep(10)
        wait_for_pid(path, tries - 1)

      _ ->
        flunk("no pid in #{path}")
    end
  end

  defp os_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  # Polls until the process is gone, for SIGKILL delivery that is not
  # instantaneous.
  defp gone_within?(pid, tries) do
    cond do
      not os_alive?(pid) ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        gone_within?(pid, tries - 1)
    end
  end

  test "runs in the working directory and merges stderr", %{tmp_dir: dir, run: run} do
    result = run.(%{"command" => "pwd; echo err >&2"})
    refute result.is_error
    assert Helyx.Message.text(result) == "#{dir}\nerr\n"
  end

  test "a non-zero exit code is in the text, not an error result", %{run: run} do
    result = run.(%{"command" => "echo partial; exit 3"})
    refute result.is_error
    assert Helyx.Message.text(result) == "partial\n\nExit code: 3"
  end

  test "no output says so", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "true"})) == "(no output)"
  end

  test "long output is cut from the head end and says so", %{run: run} do
    text = Helyx.Message.text(run.(%{"command" => "seq 1 3000"}))
    assert String.starts_with?(text, "[truncated: showing lines 1001-3000 of 3000]\n1001\n")
  end

  test "output beyond the buffer is dropped while the command runs", %{run: run} do
    text = Helyx.Message.text(run.(%{"command" => "seq 1 200000"}))

    assert String.starts_with?(
             text,
             "[output cut: only the last 204800 bytes were kept]\n[truncated:"
           )

    [_, total] = Regex.run(~r/of (\d+)\]/, text)
    assert String.to_integer(total) < 200_000
    assert String.ends_with?(text, "\n200000")
  end

  test "the command runs in its own process group", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "ps -o pgid= -p $$ | tr -d ' '; echo $$"})) =~
             ~r/^(\d+)\n\1\n$/
  end

  test "the command does not wait on stdin", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "cat"})) == "(no output)"
  end

  test "missing arguments are an error result", %{run: run} do
    assert run.(%{}).is_error
  end

  test "a detached background child does not survive the call", %{run: run} do
    pid =
      run.(%{"command" => "sleep 60 >/dev/null 2>&1 & echo $!"})
      |> Helyx.Message.text()
      |> String.trim()

    assert gone_within?(pid, 100)
  end

  test "abort ends the command and its children", %{core: core, tmp_dir: dir} do
    session = start_command(core, dir, "echo $$ > pid; sleep 60 & echo $! > child; wait")
    pid = wait_for_pid(Path.join(dir, "pid"))
    child = wait_for_pid(Path.join(dir, "child"))

    :ok = Helyx.Session.abort(session)
    refute os_alive?(pid)
    refute os_alive?(child)
    assert_receive {:helyx_event, %Helyx.Event{type: :agent_end, data: %{stop_reason: :aborted}}}
  end

  # The window: the shell exits (the port closes) before the tool Task runs
  # its cleanup, and the abort lands in between. Suspending the Task holds it
  # in that window deterministically. Only the group registered with the
  # hands can catch the child; there is no port left to scan and the Task is
  # brutally killed.
  test "abort kills the child of a shell that already exited", %{core: core, tmp_dir: dir} do
    session =
      start_command(
        core,
        dir,
        "echo $$ > pid; sleep 60 >/dev/null 2>&1 & echo $! > child; sleep 1"
      )

    pid = wait_for_pid(Path.join(dir, "pid"))
    child = wait_for_pid(Path.join(dir, "child"))

    [task_pid] =
      for task <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)),
          {:dictionary, dict} = Process.info(task, :dictionary),
          Keyword.has_key?(dict, :helyx_hands) do
        task
      end

    true = :erlang.suspend_process(task_pid)
    assert gone_within?(pid, 300), "the shell did not exit"

    :ok = Helyx.Session.abort(session)
    refute os_alive?(child)
  end

  test "a command that ignores TERM is killed after the grace period", %{core: core, tmp_dir: dir} do
    session = start_command(core, dir, "trap '' TERM; echo $$ > pid; sleep 60")
    pid = wait_for_pid(Path.join(dir, "pid"))

    :ok = Helyx.Session.abort(session)
    refute os_alive?(pid)
  end
end
