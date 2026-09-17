defmodule Helyx.Hands do
  @moduledoc """
  Runs tool calls for one session in one working directory. See ADR 0003.

  The session starts the hands and addresses it by pid. Each tool call runs
  in a Task under Core's task supervisor. The result goes back to the session
  as `{:tool_result, turn_id, call_id, {:ok, text} | {:error, text}}`. A Task
  that dies without a result gives an error result, and so does a working
  directory that is gone when the call starts. Tool calls and results are
  plain terms.

  A tool that starts an OS process group registers it with
  `Helyx.Tool.register_group/1`, so the hands hold the group id outside the
  Task, kill the group when the call delivers, however the Task ended, and
  hold the result until the group is gone.

  `cancel/2` aborts a turn: it kills the turn's tool Tasks and the operating
  system process groups they registered or still hold a port to, TERM first
  and KILL after a grace period, and returns only when every process is gone.
  """

  use GenServer

  alias Helyx.Message.ToolCall

  @grace_ms 500

  defmodule State do
    @moduledoc false
    # `tools` is the tool module by name. `tasks` holds each running Task and
    # its call, by monitor ref. `groups` holds each registered process group,
    # by the Task pid that registered it.
    @enforce_keys [:core, :cwd, :session]
    defstruct [:core, :cwd, :session, tools: %{}, tasks: %{}, groups: %{}]
  end

  @doc "Starts the hands for a session. Takes `core:`, `cwd:`, and `session:`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, struct!(State, opts))

  @doc "Returns the specs of the tools the hands can run."
  @spec tools(pid()) :: [Helyx.Tool.spec()]
  def tools(hands), do: GenServer.call(hands, :tools)

  @doc "Starts a tool call. The result is sent to the session."
  @spec run(pid(), String.t(), ToolCall.t()) :: :ok
  def run(hands, turn_id, %ToolCall{} = call), do: GenServer.call(hands, {:run, turn_id, call})

  @doc "Cancels the turn's tool Tasks and their processes. Returns when all are gone."
  @spec cancel(pid(), String.t()) :: :ok
  def cancel(hands, turn_id), do: GenServer.call(hands, {:cancel, turn_id}, :infinity)

  # The tool table comes from Core. The session checks it for duplicate
  # names before it starts the hands, so this match holds.
  @impl true
  def init(%State{core: core} = state) do
    {:ok, tools} = Helyx.Tool.by_name(core)
    {:ok, %{state | tools: tools}}
  end

  @impl true
  def handle_call(:tools, _from, state) do
    {:reply, Enum.map(Map.values(state.tools), &Helyx.Tool.spec/1), state}
  end

  def handle_call({:run, turn_id, call}, _from, state) do
    tool = if File.dir?(state.cwd), do: Map.get(state.tools, call.name, :unknown), else: :no_cwd
    cwd = state.cwd
    hands = self()

    task =
      Task.Supervisor.async_nolink(Helyx.Core.task_supervisor(state.core), fn ->
        Process.put(:helyx_hands, hands)
        run_tool(tool, call, cwd)
      end)

    {:reply, :ok, %{state | tasks: Map.put(state.tasks, task.ref, {task, turn_id, call.id})}}
  end

  # A group registered by a Task that already delivered is killed at once
  # instead of stored, so it cannot leak.
  def handle_call({:register_group, group}, {pid, _tag}, state) do
    if Enum.any?(state.tasks, fn {_ref, {task, _turn, _call}} -> task.pid == pid end) do
      {:reply, :ok, %{state | groups: Map.put(state.groups, pid, group)}}
    else
      signal(group, "KILL")
      {:reply, :ok, state}
    end
  end

  def handle_call({:cancel, turn_id}, _from, state) do
    {cancelled, kept} =
      Map.split_with(state.tasks, fn {_ref, {_task, id, _call_id}} -> id == turn_id end)

    tasks = for {_ref, {task, _id, _call_id}} <- cancelled, do: task
    pids = Enum.map(tasks, & &1.pid)
    {registered, groups} = Map.split(state.groups, pids)
    scanned = Enum.flat_map(pids, &group_leaders/1)
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    kill_groups(Enum.uniq(Map.values(registered) ++ scanned))
    {:reply, :ok, %{state | tasks: kept, groups: groups}}
  end

  @impl true
  def handle_info({ref, result}, %State{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, deliver(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, deliver(ref, {:error, "tool crashed: #{inspect(reason)}"}, state)}
  end

  # A reply or :DOWN for a Task that was already delivered.
  def handle_info(_message, state), do: {:noreply, state}

  # No process survives its call: the registered group is killed when the
  # result delivers, however the Task ended, and the result is held until
  # the group is gone, so the next call cannot overlap a dying one. Straight
  # SIGKILL: the call is over, nothing in the group has output anyone will
  # read.
  # ponytail: a process stuck in uninterruptible kernel I/O stops blocking
  # the result after 5s, the same ceiling as cancel.
  defp deliver(ref, result, state) do
    {{task, turn_id, call_id}, tasks} = Map.pop!(state.tasks, ref)
    {group, groups} = Map.pop(state.groups, task.pid)

    if group do
      signal(group, "KILL")
      await_gone([group], 5_000)
    end

    send(state.session, {:tool_result, turn_id, call_id, result})
    %{state | tasks: tasks, groups: groups}
  end

  # The os pids of the ports a Task opened. Each is a process group leader,
  # because the bash tool starts its command with setpgrp. `Port.info/2` is
  # nil for a port that already closed. Covers a call cancelled before it
  # registered its group.
  defp group_leaders(task_pid) do
    for port <- Port.list(),
        Port.info(port, :connected) == {:connected, task_pid},
        {:os_pid, os_pid} <- [Port.info(port, :os_pid)] do
      os_pid
    end
  end

  defp kill_groups(groups) do
    Enum.each(groups, &signal(&1, "TERM"))
    groups = await_gone(groups, @grace_ms)
    Enum.each(groups, &signal(&1, "KILL"))
    # ponytail: an unkillable process stops blocking the reply after 5s.
    await_gone(groups, 5_000)
    :ok
  end

  defp signal(group, name) do
    System.cmd("kill", ["-#{name}", "--", "-#{group}"], stderr_to_stdout: true)
  end

  # Polls until every group is empty or `left` ms pass. Returns the groups
  # that still have a process.
  defp await_gone(groups, left) do
    case Enum.filter(groups, &alive?/1) do
      [] ->
        []

      alive when left <= 0 ->
        alive

      alive ->
        Process.sleep(20)
        await_gone(alive, left - 20)
    end
  end

  defp alive?(group) do
    match?({_, 0}, System.cmd("kill", ["-0", "--", "-#{group}"], stderr_to_stdout: true))
  end

  defp run_tool(:unknown, call, _cwd), do: {:error, "unknown tool: #{call.name}"}
  defp run_tool(:no_cwd, _call, cwd), do: {:error, "working directory does not exist: #{cwd}"}

  defp run_tool(tool, call, cwd) do
    case tool.run(call.arguments, cwd) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, text} when is_binary(text) -> {:error, text}
      other -> {:error, "tool #{call.name} returned #{inspect(other)}"}
    end
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end
end
