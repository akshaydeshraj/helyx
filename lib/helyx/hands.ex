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

  A tool that creates an OS resource holds it with `Helyx.Tool.hold/1`. The
  hands then keep an opaque handle outside the Task. When the call
  delivers, however the Task ended, the hands call the tool's `release/3`
  with the Task's handles. The result goes to the session only after the
  release returns. The OS work lives in the tool, never here.

  The release runs in its own Task with a deadline. A handle is
  unconfirmed when the release returns it. All the handles of a release are
  unconfirmed when the release times out, raises, exits, or returns a bad
  value. An unconfirmed handle makes the result an error. The tool gets
  `:retry` for it at the start of each later tool call. While a handle is
  unconfirmed, the hands refuse tool calls with an error result. Chat,
  abort, and quit are not blocked.

  At init, each tool's optional `check/0` runs; a failed check stops the
  hands with `{:tool_unavailable, name, reason}`, so the session fails to
  start with a clear error.

  `stream/4` runs the stream of a harness provider call the same way, as
  a Task of the hands with the provider module in the place of the tool,
  because the harness program is the turn's tool runner (ADR 0004). Its
  terminal goes to the session as `{:stream_end, turn_id, terminal}` after
  the release. A crash gives `{:error, {:task_exit, reason}}`, and an
  unconfirmed handle an error terminal. While a handle is unconfirmed the
  stream is refused with an error terminal, like a tool call.

  `cancel/2` aborts a turn: it kills the turn's tool and stream Tasks and calls
  `release/3` with `:cancel` for their handles, one release Task per tool,
  in parallel, with one deadline. It returns only when every release has
  returned or timed out. An unconfirmed handle is reported as an error.
  """

  use GenServer

  # The release deadline of a retry, for all tools together.
  @retry_ms 1_000

  alias Helyx.Message.ToolCall

  defmodule State do
    @moduledoc false
    # `tools` is the tool module by name. `tasks` holds each running Task,
    # its turn, its call id, and its tool module, by monitor ref. `held`
    # holds the handles per Task pid. `unconfirmed` holds the handles that
    # no release confirmed, per tool module. `release_ms` is the release
    # deadline of a delivery or a cancel, a seam for tests.
    @enforce_keys [:core, :cwd, :session]
    defstruct [
      :core,
      :cwd,
      :session,
      tools: %{},
      tasks: %{},
      held: %{},
      unconfirmed: %{},
      release_ms: 20_000
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
  Starts the stream of a harness provider call: `fun` runs in a Task of the
  hands and returns the terminal stream event, which is sent to the session
  as `{:stream_end, turn_id, terminal}` after the release of the provider's
  handles.
  """
  @spec stream(pid(), String.t(), module(), (-> term())) :: :ok
  def stream(hands, turn_id, provider, fun) when is_function(fun, 0),
    do: GenServer.call(hands, {:stream, turn_id, provider, fun})

  @doc """
  Cancels the turn's tool Tasks and releases their handles. Returns when
  every release has returned, or an error naming the unconfirmed handles.
  """
  @spec cancel(pid(), String.t()) :: :ok | {:error, String.t()}
  def cancel(hands, turn_id), do: GenServer.call(hands, {:cancel, turn_id}, :infinity)

  @doc """
  Sends the request of `cancel/2` and returns at once, so the caller stays
  free during the release. The answer arrives as a message; give each message
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
    state = retry(state)

    if state.unconfirmed == %{} do
      {:reply, :ok, start_task(state, turn_id, call)}
    else
      {:reply, :ok, refuse(state, turn_id, call.id)}
    end
  end

  def handle_call({:stream, turn_id, provider, fun}, _from, state) do
    state = retry(state)

    if state.unconfirmed == %{} do
      {:reply, :ok, spawn_task(state, turn_id, :stream, provider, fun)}
    else
      {:reply, :ok, refuse(state, turn_id, :stream)}
    end
  end

  # A handle from a Task that was already killed is dropped: the tool frees
  # the resource when its Task dies (see `Helyx.Tool.hold/1`). A tool with
  # no `release/3` gets `:no_release`, and `Helyx.Tool.hold/1` raises in its
  # Task.
  def handle_call({:hold, handle}, {pid, _tag}, state) do
    case Enum.find_value(state.tasks, fn {_ref, {task, _, _, tool}} -> task.pid == pid && tool end) do
      nil ->
        {:reply, :ok, state}

      tool ->
        if function_exported?(tool, :release, 3) do
          held = Map.update(state.held, pid, [handle], &[handle | &1])
          {:reply, :ok, %{state | held: held}}
        else
          {:reply, :no_release, state}
        end
    end
  end

  def handle_call({:cancel, turn_id}, _from, state) do
    {cancelled, kept} =
      Map.split_with(state.tasks, fn {_ref, {_task, id, _call_id, _tool}} -> id == turn_id end)

    cancelled = Map.values(cancelled)
    Enum.each(cancelled, fn {task, _, _, _} -> Task.shutdown(task, :brutal_kill) end)
    {taken, held} = Map.split(state.held, Enum.map(cancelled, fn {task, _, _, _} -> task.pid end))

    by_tool =
      Enum.reduce(cancelled, %{}, fn {task, _, _, tool}, acc ->
        add_handles(acc, %{tool => Map.get(taken, task.pid, [])})
      end)

    left = release(by_tool, :cancel, state.release_ms, state.core)
    state = %{state | tasks: kept, held: held, unconfirmed: add_handles(state.unconfirmed, left)}

    {:reply, unconfirmed_error(left) || :ok, state}
  end

  @impl true
  def handle_info({ref, result}, %State{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, deliver(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, deliver(ref, {:exit, reason}, state)}
  end

  # A Task's exit signal (its reply or :DOWN carries the outcome), or a
  # reply or :DOWN for a Task that was already delivered. The session's exit
  # never lands here: it is the parent, and a trapped parent exit stops the
  # GenServer before handle_info.
  def handle_info(_message, state), do: {:noreply, state}

  # The hands stop only for a trapped reason; on an untrappable kill the
  # links do the same work. Each tool frees its resources when its Task dies
  # (see `Helyx.Tool.hold/1`).
  @impl true
  def terminate(_reason, state) do
    for {_ref, {task, _turn, _call, _tool}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  # No resource survives its call: the handles are released when the result
  # delivers, however the Task ended, and the result waits until the
  # release returns, so the next call cannot overlap a dying one. A handle
  # the release does not confirm makes the result an error.
  defp deliver(ref, result, state) do
    {{task, turn_id, call_id, tool}, tasks} = Map.pop!(state.tasks, ref)
    {handles, held} = Map.pop(state.held, task.pid, [])
    left = release(%{tool => handles}, :deliver, state.release_ms, state.core)

    send(state.session, outcome(turn_id, call_id, unconfirmed_error(left) || result))
    %{state | tasks: tasks, held: held, unconfirmed: add_handles(state.unconfirmed, left)}
  end

  defp outcome(turn_id, :stream, {:exit, reason}),
    do: {:stream_end, turn_id, {:error, {:task_exit, reason}}}

  defp outcome(turn_id, :stream, terminal), do: {:stream_end, turn_id, terminal}

  defp outcome(turn_id, call_id, {:exit, reason}),
    do: outcome(turn_id, call_id, {:error, "tool crashed: #{inspect(reason)}"})

  defp outcome(turn_id, call_id, result), do: {:tool_result, turn_id, call_id, scrub(result)}

  defp start_task(state, turn_id, call) do
    tool = if File.dir?(state.cwd), do: Map.get(state.tools, call.name, :unknown), else: :no_cwd
    cwd = state.cwd
    spawn_task(state, turn_id, call.id, tool, fn -> run_tool(tool, call, cwd) end)
  end

  # `id` is the call id, or `:stream` for a provider stream; `module` is the
  # tool or the provider whose `release/3` gets the Task's handles.
  defp spawn_task(state, turn_id, id, module, fun) do
    hands = self()

    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), fn ->
        Process.put(:helyx_hands, hands)
        fun.()
      end)

    %{state | tasks: Map.put(state.tasks, task.ref, {task, turn_id, id, module})}
  end

  defp refuse(state, turn_id, id) do
    error =
      "a resource from an earlier call could not be released " <>
        "(#{handles_text(state.unconfirmed)}); the call was not run"

    send(state.session, outcome(turn_id, id, {:error, error}))
    state
  end

  # Gives every unconfirmed handle to its tool again, with one short
  # deadline for all tools, and keeps the ones still held.
  defp retry(state),
    do: %{state | unconfirmed: release(state.unconfirmed, :retry, @retry_ms, state.core)}

  # Calls `release/3` of each tool with its handles, one Task per tool, in
  # parallel, with one deadline. A Task that is still running at the
  # deadline is killed, and the wait returns only when it is gone. Returns
  # the handles still held, per tool. A reply that arrives before the kill
  # counts, because the release did return. A release that raises, exits, times
  # out, or returns anything but a proper list of given handles confirms
  # none of them. A tool with no handles gets no call.
  defp release(by_tool, mode, ms, core) do
    deadline = System.monotonic_time(:millisecond) + ms
    supervisor = Helyx.Core.task_supervisor(core)

    tasks =
      for {tool, handles} <- by_tool, handles != [] do
        {tool, handles,
         Task.Supervisor.async(supervisor, tool, :release, [handles, mode, deadline])}
      end

    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    results =
      Task.yield_many(Enum.map(tasks, &elem(&1, 2)), timeout: timeout, on_timeout: :kill_task)

    for {{tool, handles, _task}, {_task2, result}} <- Enum.zip(tasks, results),
        left = still_held(result, handles),
        left != [],
        into: %{},
        do: {tool, left}
  end

  defp still_held({:ok, left}, handles) when is_list(left) do
    if List.improper?(left) or left -- handles != [], do: handles, else: left
  end

  defp still_held(_failed, handles), do: handles

  defp add_handles(a, b), do: Map.merge(a, b, fn _tool, x, y -> x ++ y end)

  defp unconfirmed_error(left) when left == %{}, do: nil

  defp unconfirmed_error(left),
    do: {:error, "a resource of the call could not be released (#{handles_text(left)})"}

  defp handles_text(by_tool) do
    by_tool
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.map(&inspect/1)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  # Every result leaves the hands through here, so text is made valid once,
  # for the ok, error, crash, and catch paths alike. Valid text, the common
  # case, is passed through without a copy.
  defp scrub({status, text}) do
    if String.valid?(text), do: {status, text}, else: {status, String.replace_invalid(text)}
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
