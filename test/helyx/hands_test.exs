defmodule Helyx.HandsTest do
  # The hands' group bookkeeping, driven directly with the test process as
  # the session. The `kill_cmd` seam fakes kill(1), so a group that survives
  # KILL is testable without an unkillable OS process.
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Helyx.Test.Provider,
      Helyx.Test.Tool.Register,
      Helyx.Test.Tool.Upcase
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp start_hands(core, opts) do
    {:ok, hands} =
      Helyx.Hands.start_link([core: core, cwd: File.cwd!(), session: self()] ++ opts)

    hands
  end

  defp call(id, name, arguments), do: %ToolCall{id: id, name: name, arguments: arguments}

  # A kill(1) fake: reports every group alive while the Agent holds true,
  # and echoes each invocation to the test process.
  defp fake_kill(agent, test_pid) do
    fn args ->
      send(test_pid, {:kill, args})

      case {args, Agent.get(agent, & &1)} do
        {["-0" | _], true} -> {"", 0}
        {["-0" | _], false} -> {"no such process", 1}
        _ -> {"", 0}
      end
    end
  end

  test "a group that survives KILL gives an error result and blocks the next call", %{core: core} do
    {:ok, agent} = Agent.start_link(fn -> true end)
    hands = start_hands(core, kill_cmd: fake_kill(agent, self()), wait_ms: 0)

    :ok = Helyx.Hands.run(hands, "t1", call("c1", "register", %{"groups" => [4242]}))
    assert_receive {:tool_result, "t1", "c1", {:error, text}}, 2_000
    assert text =~ "could not be killed"
    assert text =~ "4242"
    assert_received {:kill, ["-KILL", "--", "-4242"]}

    # The next call is refused with an error result, and the stuck group is
    # signalled again first.
    :ok = Helyx.Hands.run(hands, "t1", call("c2", "upcase", %{"text" => "hi"}))
    assert_receive {:tool_result, "t1", "c2", {:error, text}}, 2_000
    assert text =~ "earlier call"
    assert text =~ "4242"
    assert_received {:kill, ["-KILL", "--", "-4242"]}

    # Once the group is gone, the stuck set clears and calls run again.
    Agent.update(agent, fn _ -> false end)
    :ok = Helyx.Hands.run(hands, "t1", call("c3", "upcase", %{"text" => "hi"}))
    assert_receive {:tool_result, "t1", "c3", {:ok, "HI"}}, 2_000
  end

  test "cancel reports a group that survives KILL", %{core: core} do
    {:ok, agent} = Agent.start_link(fn -> true end)
    hands = start_hands(core, kill_cmd: fake_kill(agent, self()), wait_ms: 0)

    :ok =
      Helyx.Hands.run(hands, "t1", call("c1", "register", %{"groups" => [777], "ms" => 60_000}))

    await_registered(hands)

    assert {:error, text} = Helyx.Hands.cancel(hands, "t1")
    assert text =~ "could not be killed"
    assert text =~ "777"

    # The survivor is remembered: the next call is refused.
    :ok = Helyx.Hands.run(hands, "t1", call("c2", "upcase", %{"text" => "hi"}))
    assert_receive {:tool_result, "t1", "c2", {:error, text}}, 2_000
    assert text =~ "earlier call"
  end

  test "two groups registered by one call are both killed at delivery", %{core: core} do
    hands = start_hands(core, [])
    g1 = spawn_group()
    g2 = spawn_group()

    :ok = Helyx.Hands.run(hands, "t1", call("c1", "register", %{"groups" => [g1, g2]}))
    assert_receive {:tool_result, "t1", "c1", {:ok, "registered"}}, 5_000
    refute group_alive?(g1)
    refute group_alive?(g2)
  end

  test "a tool whose check fails stops the session with a clear error" do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core, name: core, plugins: [Helyx.Test.Provider, Helyx.Test.Tool.Unavailable]}
    )

    assert {:error, {:tool_unavailable, "unavailable", "the frob is missing"}} =
             Helyx.Session.start(core, model: "test/ok")
  end

  # Polls until the running Task has registered its group, so cancel finds
  # it held.
  defp await_registered(hands, tries \\ 200) do
    cond do
      map_size(:sys.get_state(hands).groups) > 0 ->
        :ok

      tries == 0 ->
        flunk("no group was registered")

      true ->
        Process.sleep(10)
        await_registered(hands, tries - 1)
    end
  end

  # A real OS process group: perl makes itself a group leader, reports its
  # pid, and sleeps.
  defp spawn_group do
    perl = System.find_executable("perl")

    port =
      Port.open({:spawn_executable, perl}, [
        :binary,
        {:args, ["-e", ~S|setpgrp(0, 0); syswrite(STDOUT, "$$\n"); exec "sleep", "60"|]}
      ])

    receive do
      {^port, {:data, line}} -> String.to_integer(String.trim(line))
    after
      2_000 -> flunk("no group pid")
    end
  end

  defp group_alive?(group) do
    match?({_, 0}, System.cmd("kill", ["-0", "--", "-#{group}"], stderr_to_stdout: true))
  end
end
