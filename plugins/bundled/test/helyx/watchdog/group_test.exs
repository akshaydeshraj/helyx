defmodule Helyx.Watchdog.GroupTest do
  # The release of the handles of `Helyx.Watchdog`. A fake kill(1) makes a group that
  # survives KILL testable without an unkillable OS process.
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers, only: [group_gone_within?: 2]

  alias Helyx.Watchdog.Group

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  # A kill(1) fake over a set of live groups: KILL removes a group unless it
  # is in `unkillable`, a probe checks the set. A watchdog in `reaps`, a map
  # of watchdog to command group, exits by itself once its command group is
  # gone. Every run is echoed to the test process.
  defp fake_kill(live, unkillable \\ [], reaps \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> MapSet.new(live) end)
    test = self()

    fn args ->
      send(test, {:kill, args})

      case args do
        ["-0", "--", target] ->
          probe(Agent.get(agent, & &1), reaps, target)

        ["-KILL", "--" | targets] ->
          killed =
            MapSet.new(targets, &(-String.to_integer(&1)))
            |> MapSet.difference(MapSet.new(unkillable))

          Agent.update(agent, &MapSet.difference(&1, killed))
          {"", 0}

        ["-TERM", "--" | _targets] ->
          {"", 0}
      end
    end
  end

  defp probe(live, reaps, target) do
    group = -String.to_integer(target)
    reaped? = Map.has_key?(reaps, group) and not MapSet.member?(live, reaps[group])

    if MapSet.member?(live, group) and not reaped?,
      do: {"", 0},
      else: {"kill: #{target}: No such process", 1}
  end

  defp signals(acc \\ []) do
    receive do
      {:kill, ["-0" | _]} -> signals(acc)
      {:kill, [signal, "--" | targets]} -> signals([{signal, targets} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a group that survives KILL is still held, and the deadline bounds the wait" do
    kill = fake_kill([4242], [4242])
    start = System.monotonic_time(:millisecond)

    assert Group.release([{:command, 4242}], :deliver, deadline(100), kill) == [{:command, 4242}]
    assert System.monotonic_time(:millisecond) - start < 300
    assert signals() == [{"-KILL", ["-4242"]}]
  end

  # A watchdog that does not exit by itself gets its KILL after one wait of
  # 5,000 ms, only after the command group is gone.
  test "the watchdog is KILLed only after the command group is gone" do
    kill = fake_kill([100, 200])

    assert Group.release([{:watchdog, 200}, {:command, 100}], :deliver, deadline(20_000), kill) ==
             []

    assert signals() == [{"-KILL", ["-100"]}, {"-KILL", ["-200"]}]
  end

  test "a cancel TERMs the command group before the KILL, and never the watchdog" do
    kill = fake_kill([100, 200], [], %{200 => 100})

    assert Group.release([{:command, 100}, {:watchdog, 200}], :cancel, deadline(2_000), kill) ==
             []

    assert signals() == [{"-TERM", ["-100"]}, {"-KILL", ["-100"]}]
  end

  test "a retry KILLs every group and probes once, with no wait" do
    kill = fake_kill([100, 200], [100, 200])
    start = System.monotonic_time(:millisecond)
    handles = [{:command, 100}, {:watchdog, 200}]

    assert Group.release(handles, :retry, deadline(1_000), kill) == handles
    assert System.monotonic_time(:millisecond) - start < 100
    assert signals() == [{"-KILL", ["-100", "-200"]}]
  end

  test "a group below 2 is never signalled, and an unknown handle stays held" do
    kill = fake_kill([])
    handles = [{:command, 1}, {:watchdog, 0}, :other]
    assert Group.release(handles, :cancel, deadline(100), kill) == handles
    assert signals() == []
  end

  test "a probe that fails for another reason than a missing group keeps it held" do
    kill = fn
      ["-0" | _] -> {"kill: -340: Operation not permitted", 1}
      _ -> {"", 0}
    end

    assert Group.release([{:command, 340}], :retry, deadline(100), kill) == [{:command, 340}]
  end

  test "no kill run starts after the deadline, and every group stays held" do
    kill = fake_kill([100, 200])
    handles = [{:command, 100}, {:watchdog, 200}]
    assert Group.release(handles, :deliver, deadline(0), kill) == handles
    refute_received {:kill, _}
  end

  test "a deadline that passes during the release stops the kill runs" do
    kill = fake_kill([100, 200], [100, 200])
    slow = fn args -> Process.sleep(30) && kill.(args) end
    until = deadline(50)
    handles = [{:command, 100}, {:watchdog, 200}]

    assert Group.release(handles, :cancel, until, slow) == handles
    # Only a run that started before the deadline ends after it.
    assert System.monotonic_time(:millisecond) - until < 35
  end

  test "the TERM grace is 500 ms" do
    kill = fake_kill([100])
    start = System.monotonic_time(:millisecond)
    assert Group.release([{:command, 100}], :cancel, deadline(10_000), kill) == []
    assert (System.monotonic_time(:millisecond) - start) in 500..700
  end

  test "a KILL wait ends after 5,000 ms" do
    kill = fake_kill([4242], [4242])
    start = System.monotonic_time(:millisecond)

    assert Group.release([{:command, 4242}], :deliver, deadline(20_000), kill) == [
             {:command, 4242}
           ]

    assert (System.monotonic_time(:millisecond) - start) in 5_000..5_300
  end

  test "no wait passes the deadline" do
    kill = fake_kill([4242], [4242])
    until = deadline(50)
    Group.release([{:command, 4242}], :cancel, until, kill)
    assert System.monotonic_time(:millisecond) - until < 15
  end

  test "two real groups are both killed" do
    g1 = spawn_group()
    g2 = spawn_group()
    assert Group.release([{:command, g1}, {:command, g2}], :deliver, deadline(5_000)) == []
    assert group_gone_within?(g1, 0)
    assert group_gone_within?(g2, 0)
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
end
