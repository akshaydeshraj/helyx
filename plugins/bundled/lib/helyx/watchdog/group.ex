defmodule Helyx.Watchdog.Group do
  @moduledoc false
  # The release of the handles of `Helyx.Watchdog`: `{:command, group}` for the
  # command's process group and `{:watchdog, os_pid}` for the watchdog, which
  # is its own group. Returns the handles whose group still has a process,
  # and every handle that is not one of these two forms, because nothing
  # confirms that it is released.
  #
  # Command groups go first, then the watchdogs. A watchdog is a reaper: it
  # is swept only after every command group is gone or still held, because a
  # KILLed watchdog cannot reap its command, and where PID 1 does not reap
  # orphans the zombie would hold its group forever. It exits by itself once
  # the command is reaped; the KILL is the fallback for a watchdog that never
  # does. The watchdog ignores TERM, so only the command groups get one.
  #
  # `:deliver` KILLs straight away: the call is over, nothing in the group
  # has output anyone will read. `:cancel` TERMs first and KILLs after the
  # grace period. `:retry` KILLs again and probes once, with no wait.
  #
  # No kill(1) run starts at or after the deadline: a skipped probe counts
  # the group as alive, so the handle is returned as still held. A group is
  # gone only when kill(1) reports "No such process". Any other failure,
  # such as a group of another user, keeps it held.

  @grace_ms 500
  @wait_ms 5_000

  @doc false
  # `kill` runs kill(1); tests pass a fake.
  def release(handles, mode, deadline, kill \\ &kill_cmd/1) do
    kill = until_deadline(deadline, kill)
    # `kill -- -1` would signal every process the user may signal, so a
    # group below 2 is never signalled.
    {valid, unknown} = Enum.split_with(handles, &valid?/1)
    commands = for {:command, group} <- valid, do: group
    watchdogs = for {:watchdog, group} <- valid, do: group
    {commands, watchdogs} = sweep(commands, watchdogs, mode, deadline, kill)
    Enum.map(commands, &{:command, &1}) ++ Enum.map(watchdogs, &{:watchdog, &1}) ++ unknown
  end

  defp valid?({kind, group})
       when kind in [:command, :watchdog] and is_integer(group) and group > 1,
       do: true

  defp valid?(_handle), do: false

  defp sweep(commands, watchdogs, :retry, _deadline, kill) do
    signal(commands ++ watchdogs, "KILL", kill)
    {alive(commands, kill), alive(watchdogs, kill)}
  end

  defp sweep(commands, watchdogs, mode, deadline, kill) do
    left = if mode == :cancel, do: term(commands, deadline, kill), else: commands
    {kill_and_wait(left, deadline, kill), sweep_watchdogs(watchdogs, deadline, kill)}
  end

  defp term(commands, deadline, kill) do
    signal(commands, "TERM", kill)
    poll_gone(commands, within(deadline, @grace_ms), kill)
  end

  defp sweep_watchdogs(watchdogs, deadline, kill) do
    waiting = poll_gone(watchdogs, within(deadline, @wait_ms), kill)
    kill_and_wait(waiting, deadline, kill)
  end

  defp kill_and_wait(groups, deadline, kill) do
    signal(groups, "KILL", kill)
    poll_gone(groups, within(deadline, @wait_ms), kill)
  end

  defp within(deadline, ms), do: min(System.monotonic_time(:millisecond) + ms, deadline)

  # One kill(1) run signals the whole set.
  defp signal([], _name, _kill), do: :ok

  defp signal(groups, name, kill) do
    kill.(["-#{name}", "--" | Enum.map(groups, &"-#{&1}")])
    :ok
  end

  # Polls until every group is empty or the monotonic time `until` passes.
  # No sleep passes `until`. Returns the groups that still have a process.
  defp poll_gone(groups, until, kill) do
    case alive(groups, kill) do
      [] ->
        []

      alive ->
        left_ms = until - System.monotonic_time(:millisecond)

        if left_ms <= 0 do
          alive
        else
          Process.sleep(min(20, left_ms))
          poll_gone(alive, until, kill)
        end
    end
  end

  defp alive(groups, kill), do: Enum.reject(groups, &gone?(kill.(["-0", "--", "-#{&1}"])))

  defp gone?({text, status}) when status != 0, do: String.contains?(text, "No such process")
  defp gone?(_alive_or_skipped), do: false

  defp until_deadline(deadline, kill) do
    fn args ->
      if System.monotonic_time(:millisecond) < deadline, do: kill.(args), else: :skipped
    end
  end

  # The C locale keeps the error text of kill(1) in English.
  defp kill_cmd(args),
    do: System.cmd("kill", args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
end
