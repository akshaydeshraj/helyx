defmodule Helyx.Hands do
  @moduledoc """
  Runs tool calls for one session in one working directory. See ADR 0003
  and ADR 0004.

  The session starts the hands and addresses it by pid. Each tool call runs
  in a Task under Core's task supervisor, linked to the hands: the hands
  trap exits, so a Task crash is a message, and a death of the hands, even
  an untrappable kill, takes every running Task with it. The result goes
  back to the session as `{:tool_result, turn_id, call_id, {:ok, text} |
  {:error, text}}`. A Task that dies without a result gives an error result,
  and so does a working directory that is gone when the call starts. Tool
  calls and results are plain terms. Result text is valid UTF-8 when it
  leaves the hands: each invalid sequence is replaced with U+FFFD, so a
  later encoder never sees invalid stored text.

  A tool that starts an OS process group registers it with
  `Helyx.Tool.register_group/2`, so the hands hold the groups outside the
  Task, kill them when the call delivers, however the Task ended, and hold
  the result until every group is gone. A group registered as `:watchdog`
  is swept only after every command group is gone or stuck, and gets time
  to exit by itself first, so the hands never KILL a reaper that still has
  work. A group that survives KILL past the wait is stuck: the result
  becomes an error, the group is signalled again at the start of each
  later tool call, and the hands refuse tool calls
  with an error result while a stuck group is alive. Chat, abort, and quit
  are not blocked.

  At init, each tool's optional `check/0` runs; a failed check stops the
  hands with `{:tool_unavailable, name, reason}`, so the session fails to
  start with a clear error.

  `cancel/2` aborts a turn: it kills the turn's tool Tasks and the operating
  system process groups they registered, TERM first and KILL after a grace
  period, and returns only when every process is gone. A group that survives
  is reported as an error and joins the stuck set.
  """

  use GenServer

  alias Helyx.Message.ToolCall

  @grace_ms 500

  defmodule State do
    @moduledoc false
    # `tools` is the tool module by name. `tasks` holds each running Task and
    # its call, by monitor ref. `groups` holds the registered process groups
    # per Task pid, as a map of group id to kind (:command or :watchdog).
    # `stuck` holds groups that survived KILL. `kill_cmd` and `wait_ms` are
    # seams for tests: the kill(1) runner and the ceiling of each wait for a
    # killed group.
    @enforce_keys [:core, :cwd, :session]
    defstruct [
      :core,
      :cwd,
      :session,
      tools: %{},
      tasks: %{},
      groups: %{},
      stuck: MapSet.new(),
      kill_cmd: &Helyx.Hands.kill_cmd/1,
      wait_ms: 5_000
    ]
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

  @doc """
  Cancels the turn's tool Tasks and their processes. Returns when all are
  gone, or an error naming the groups that survived KILL.
  """
  @spec cancel(pid(), String.t()) :: :ok | {:error, String.t()}
  def cancel(hands, turn_id), do: GenServer.call(hands, {:cancel, turn_id}, :infinity)

  @doc """
  Sends the request of `cancel/2` and returns at once, so the caller stays
  free during the sweep. The answer arrives as a message; give each message
  to `cancel_response/2`.
  """
  @spec request_cancel(pid(), String.t()) :: :gen_server.request_id()
  def request_cancel(hands, turn_id), do: :gen_server.send_request(hands, {:cancel, turn_id})

  @doc """
  Reads a message as the answer to a `request_cancel/2`: `{:reply, result}`
  with the result of `cancel/2`, `{:error, {reason, hands}}` when the hands
  died, or `:no_reply` when the message is not the answer.
  """
  @spec cancel_response(term(), :gen_server.request_id()) ::
          {:reply, :ok | {:error, String.t()}} | {:error, {term(), term()}} | :no_reply
  def cancel_response(message, request),
    do: :gen_server.check_response(message, request)

  @doc false
  def kill_cmd(args), do: System.cmd("kill", args, stderr_to_stdout: true)

  # The tool table comes from Core. The session checks it for duplicate
  # names before it starts the hands, so this match holds.
  @impl true
  def init(%State{core: core} = state) do
    Process.flag(:trap_exit, true)
    {:ok, tools} = Helyx.Tool.by_name(core)

    case failed_check(tools) do
      nil -> {:ok, %{state | tools: tools}}
      {name, reason} -> {:stop, {:tool_unavailable, name, reason}}
    end
  end

  defp failed_check(tools) do
    Enum.find_value(tools, fn {name, tool} ->
      with true <- function_exported?(tool, :check, 0),
           {:error, reason} <- tool.check() do
        {name, reason}
      else
        _ -> nil
      end
    end)
  end

  @impl true
  def handle_call(:tools, _from, state) do
    {:reply, Enum.map(Map.values(state.tools), &Helyx.Tool.spec/1), state}
  end

  def handle_call({:run, turn_id, call}, _from, state) do
    state = clear_stuck(state)

    if MapSet.size(state.stuck) > 0 do
      {:reply, :ok, refuse(state, turn_id, call)}
    else
      {:reply, :ok, start_task(state, turn_id, call)}
    end
  end

  # A registration from a Task that was already killed is dropped: its port
  # is closed, so the watchdog kills the group.
  def handle_call({:register_group, group, kind}, {pid, _tag}, state) do
    if Enum.any?(state.tasks, fn {_ref, {task, _turn, _call}} -> task.pid == pid end) do
      groups = Map.update(state.groups, pid, %{group => kind}, &Map.put(&1, group, kind))
      {:reply, :ok, %{state | groups: groups}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:cancel, turn_id}, _from, state) do
    {cancelled, kept} =
      Map.split_with(state.tasks, fn {_ref, {_task, id, _call_id}} -> id == turn_id end)

    tasks = for {_ref, {task, _id, _call_id}} <- cancelled, do: task
    {registered, groups} = Map.split(state.groups, Enum.map(tasks, & &1.pid))
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

    # Killing the Tasks closed their ports, so each watchdog TERMs its own
    # group; the TERM from here covers a watchdog that is already gone. The
    # watchdogs get no TERM (they ignore it) and are swept last.
    merged = registered |> Map.values() |> Enum.reduce(%{}, &Map.merge(&2, &1))
    {commands, watchdogs} = split_kinds(merged)
    signal(commands, "TERM", state.kill_cmd)
    left = await_gone(commands, @grace_ms, state.kill_cmd)
    {left, state} = kill_and_wait(left, state.wait_ms, state)
    {left_watchdogs, state} = sweep_watchdogs(watchdogs, state)

    {:reply, killed_error(left ++ left_watchdogs) || :ok, %{state | tasks: kept, groups: groups}}
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

  # A Task's exit signal (its reply or :DOWN carries the outcome), or a
  # reply or :DOWN for a Task that was already delivered. The session's exit
  # never lands here: it is the parent, and a trapped parent exit stops the
  # GenServer before handle_info.
  def handle_info(_message, state), do: {:noreply, state}

  # The hands stop only for a trapped reason; on an untrappable kill the
  # links do the same work. The watchdogs see the closed ports and kill the
  # OS side.
  @impl true
  def terminate(_reason, state) do
    for {_ref, {task, _turn, _call}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  # No process survives its call: the registered groups are killed when the
  # result delivers, however the Task ended, and the result is held until
  # every group is gone, so the next call cannot overlap a dying one.
  # Straight SIGKILL: the call is over, nothing in the group has output
  # anyone will read. A group that survives makes the result an error.
  defp deliver(ref, result, state) do
    {{task, turn_id, call_id}, tasks} = Map.pop!(state.tasks, ref)
    {groups, remaining} = Map.pop(state.groups, task.pid, %{})
    {commands, watchdogs} = split_kinds(groups)
    {left, state} = kill_and_wait(commands, state.wait_ms, state)
    {left_watchdogs, state} = sweep_watchdogs(watchdogs, state)

    result = killed_error(left ++ left_watchdogs) || result
    send(state.session, {:tool_result, turn_id, call_id, scrub(result)})
    %{state | tasks: tasks, groups: remaining}
  end

  defp start_task(state, turn_id, call) do
    tool = if File.dir?(state.cwd), do: Map.get(state.tools, call.name, :unknown), else: :no_cwd
    cwd = state.cwd
    hands = self()

    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), fn ->
        Process.put(:helyx_hands, hands)
        run_tool(tool, call, cwd)
      end)

    %{state | tasks: Map.put(state.tasks, task.ref, {task, turn_id, call.id})}
  end

  defp refuse(state, turn_id, call) do
    error =
      "a process from an earlier call could not be killed " <>
        "(process group #{groups_text(state.stuck)}); the call was not run"

    send(state.session, {:tool_result, turn_id, call.id, {:error, error}})
    state
  end

  # Splits an id-to-kind map into command and watchdog id lists.
  defp split_kinds(groups) do
    {watchdogs, commands} = Enum.split_with(groups, fn {_group, kind} -> kind == :watchdog end)
    {Enum.map(commands, &elem(&1, 0)), Enum.map(watchdogs, &elem(&1, 0))}
  end

  # A watchdog is a reaper: it is swept only after every command group is
  # gone or stuck, because a KILLed watchdog cannot reap its command, and
  # where PID 1 does not reap orphans the zombie would hold its group, and
  # the stuck set, forever. It exits by itself once the command is reaped;
  # the KILL is the fallback for a watchdog that never does.
  defp sweep_watchdogs(watchdogs, state) do
    waiting = await_gone(watchdogs, state.wait_ms, state.kill_cmd)
    kill_and_wait(waiting, state.wait_ms, state)
  end

  # KILLs the groups, waits up to `timeout_ms` for every one to be gone, and
  # remembers survivors as stuck, so an unkillable process stops blocking
  # the hands after the wait without being forgotten (issue #37).
  defp kill_and_wait(groups, timeout_ms, state) do
    signal(groups, "KILL", state.kill_cmd)
    left = await_gone(groups, timeout_ms, state.kill_cmd)
    {left, %{state | stuck: MapSet.union(state.stuck, MapSet.new(left))}}
  end

  # Signals every stuck group again and forgets the ones that are gone. One
  # probe after the re-KILL: a group that is still there stays stuck, and
  # the next call probes again.
  defp clear_stuck(%State{stuck: stuck} = state) do
    if MapSet.size(stuck) == 0 do
      state
    else
      groups = MapSet.to_list(stuck)
      signal(groups, "KILL", state.kill_cmd)
      %{state | stuck: MapSet.new(await_gone(groups, 0, state.kill_cmd))}
    end
  end

  defp killed_error([]), do: nil

  defp killed_error(left),
    do: {:error, "a process could not be killed (process group #{groups_text(left)})"}

  defp groups_text(groups), do: Enum.join(Enum.sort(groups), ", ")

  # Every result leaves the hands through here, so text is made valid once,
  # for the ok, error, crash, and catch paths alike. Valid text, the common
  # case, is passed through without a copy.
  defp scrub({status, text}) do
    if String.valid?(text), do: {status, text}, else: {status, String.replace_invalid(text)}
  end

  # One kill(1) run signals the whole set.
  defp signal([], _name, _kill), do: :ok

  defp signal(groups, name, kill) do
    kill.(["-#{name}", "--" | Enum.map(groups, &"-#{&1}")])
    :ok
  end

  # Polls until every group is empty or the timeout of real elapsed time
  # passes. Returns the groups that still have a process.
  defp await_gone(groups, timeout_ms, kill) do
    poll_gone(groups, System.monotonic_time(:millisecond) + timeout_ms, kill)
  end

  defp poll_gone(groups, deadline, kill) do
    case Enum.filter(groups, &alive?(&1, kill)) do
      [] ->
        []

      alive ->
        if System.monotonic_time(:millisecond) >= deadline do
          alive
        else
          Process.sleep(20)
          poll_gone(alive, deadline, kill)
        end
    end
  end

  defp alive?(group, kill) do
    match?({_, 0}, kill.(["-0", "--", "-#{group}"]))
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
