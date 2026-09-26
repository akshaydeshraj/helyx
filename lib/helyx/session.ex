defmodule Helyx.Session do
  @moduledoc """
  One conversation with one agent.

  A session is a supervised process under Core. It owns the transcript and
  the current turn. Clients subscribe to its events and send prompts.

      {:ok, session} = Helyx.Session.start(core, model: "fake/echo")
      :ok = Helyx.Session.subscribe(session)
      :ok = Helyx.Session.prompt(session, "hello")
      # receive {:helyx_event, %Helyx.Event{}} ...

  Each turn runs the provider stream in a Task under Core's task supervisor,
  linked to the session: the session traps exits, so a Task crash stays a
  message, and a death of the session takes the Task, the hands, and every
  tool Task with it (ADR 0004). The Task sends each stream event to the
  session and returns the terminal stream event, `done` or `error`. The
  session builds the assistant message from the stream events and closes the
  provider call on the Task's reply. A stream that ends without a terminal
  event, or a Task that crashes, fails the turn.

  An assistant message with tool calls runs them on the session's hands
  (`Helyx.Hands`) one at a time, in call order, so two calls never touch the
  working directory at once. Each result joins the transcript as it arrives,
  and the provider is called again after the last one. The turn ends on an
  assistant message with no tool calls.

  Messages sent during a turn queue instead of failing. A steer is delivered,
  with the other queued steers in order, as user messages before the next
  provider call inside the same turn. A follow-up starts a new turn after the
  current turn ends. Anything still queued when a turn ends normally starts a
  new turn; an aborted or failed turn drops its queues. Each queue holds at
  most 32 entries; past the cap the call returns `{:error, :queue_full}`.
  Queues live in the session process only and are not persisted. Every
  change emits a `:queue_update` event.

  A provider with an external turn (`Helyx.Provider.turn/1`) runs the whole
  turn and its own tools inside one provider call (ADR 0002). Its stream
  runs as a Task of the hands, so an abort waits until its program is gone.
  It reports each completed assistant message and each tool result, which
  join the transcript as they arrive, and the turn ends when the call ends.
  A tool call with no result at the end of the call gets an `aborted` error
  result. A steer aborts the external turn and starts a new turn with the
  queued messages. The id of each fresh harness session is written to the
  session file and goes out as a `:harness_session` event.

  An abort does not block the session. The session ends the turn at once and
  asks the hands to release the turn's resources. This can take many
  seconds when a resource stays. Until the hands answer, the session
  answers every client call, but it starts no turn, because the hands
  cannot take a tool call during the release: a prompt, a steer, or a
  follow-up queues, and one turn starts with the queue when the hands have
  answered.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Helyx.{Context, Event, Message, ModelRef, SessionFile}
  alias Helyx.Session.{Queues, Transcript, Turn}

  @rejected_call_text "tool call not run: an integer in the arguments has more than " <>
                        "#{Message.max_integer_digits()} digits"

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:id, :core, :model, :provider, :turn_mode, :cwd]
    defstruct [
      :id,
      :core,
      :model,
      :provider,
      # The turn of `provider`, `:local` or `:external` (`Helyx.Provider.turn/1`).
      :turn_mode,
      :cwd,
      :hands,
      :file,
      # The registered ModelContext and Compaction plugins, or nil for none.
      :model_context,
      :compaction,
      tools: [],
      transcript: [],
      seq: 0,
      turn: nil,
      queues: %Queues{},
      provider_pids: MapSet.new(),
      # The last harness session per harness provider id: its id and the
      # number of transcript messages before it started.
      harness_sessions: %{},
      # `{request, callers}` while the hands cancel an aborted turn: the
      # request of `Helyx.Hands.request_cancel/2` and the abort callers that
      # wait for its answer.
      aborting: nil
    ]
  end

  # Public API

  @doc """
  Starts a session under Core. `:model` is required. `:cwd` defaults to the
  current directory. With `:sessions_dir` the session is written to disk as
  it runs, as JSON lines under `<sessions_dir>/<project>/<session>.jsonl`;
  without it nothing is persisted.
  """
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(core \\ Helyx.Core, opts) do
    id = Helyx.Id.new()
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)

    # The file is created only after the plugins resolve, which narrows the
    # window for an orphan file from a failed start. A supervisor failure
    # after this point still leaves one; the feature doc records that hole.
    with {:ok, {ref, provider, turn_mode}} <- resolve_model(core, Keyword.fetch!(opts, :model)),
         {:ok, _tools} <- Helyx.Tool.by_name(core),
         {:ok, file} <- create_file(opts[:sessions_dir], id, cwd, ref) do
      start_child(%State{
        id: id,
        core: core,
        model: ref,
        provider: provider,
        turn_mode: turn_mode,
        cwd: cwd,
        file: file
      })
    end
  end

  defp create_file(nil, _id, _cwd, _ref), do: {:ok, nil}

  defp create_file(dir, id, cwd, ref),
    do: SessionFile.create(dir, id, cwd, ModelRef.to_string(ref))

  @doc """
  Resumes the most recent session for the working directory from
  `:sessions_dir`, restoring the transcript and the current model. Every
  tool call without a result gets an `aborted` error result, so the next
  provider call sees complete call and result pairs.
  """
  @spec resume(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, term()}
  def resume(core \\ Helyx.Core, opts) do
    dir = Keyword.fetch!(opts, :sessions_dir)
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)

    with {:ok, resumed} <- SessionFile.resume(dir, cwd),
         {:ok, {ref, provider, turn_mode}} <- resolve_model(core, resumed.model),
         {:ok, _tools} <- Helyx.Tool.by_name(core) do
      start_child(%State{
        id: resumed.session_id,
        core: core,
        model: ref,
        provider: provider,
        turn_mode: turn_mode,
        cwd: cwd,
        file: resumed.file,
        transcript: resumed.messages,
        harness_sessions: resumed.harness_sessions
      })
    end
  end

  # A model ref string to its parsed ref, its provider plugin, and the turn
  # of that plugin, for start, resume, and a switch alike. It runs in the
  # caller, so a plugin that raises here never stops a session.
  defp resolve_model(core, string) do
    with {:ok, ref} <- ModelRef.parse(string),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider) do
      case Helyx.Provider.turn(provider) do
        {:ok, turn_mode} -> {:ok, {ref, provider, turn_mode}}
        :error -> {:error, {:bad_provider_turn, ref.provider}}
      end
    end
  end

  defp start_child(%State{id: id, core: core} = state) do
    # The plugin table of a Core does not change after start, so a plugin
    # resolved once here is the plugin a lookup per provider call would give.
    # Both interfaces are single-mode: one plugin or none (nil).
    state = %{
      state
      | model_context: List.first(Helyx.Core.plugins(core, Helyx.ModelContext)),
        compaction: List.first(Helyx.Core.plugins(core, Helyx.Compaction))
    }

    with {:ok, _pid} <-
           DynamicSupervisor.start_child(Helyx.Core.session_supervisor(core), {__MODULE__, state}) do
      {:ok, %__MODULE__{id: id, core: core}}
    end
  end

  @doc "Subscribes the caller to the session's events, delivered as `{:helyx_event, event}`."
  @spec subscribe(t()) :: :ok
  def subscribe(%__MODULE__{id: id, core: core}) do
    {:ok, _} = Registry.register(Helyx.Core.events_registry(core), id, nil)
    :ok
  end

  @doc "The pid behind a session handle, or nil when the session is not running."
  @spec pid(t()) :: pid() | nil
  def pid(%__MODULE__{id: id, core: core}), do: GenServer.whereis(via(core, id))

  @doc """
  Sends a prompt. Starts a turn if none is running. The text must be valid
  UTF-8. While an abort waits for the hands, the prompt queues as a
  follow-up, and a full queue returns `{:error, :queue_full}`.
  """
  @spec prompt(t(), String.t()) :: :ok | {:error, :turn_running | :invalid_utf8 | :queue_full}
  def prompt(%__MODULE__{id: id, core: core}, text) when is_binary(text) do
    if Message.valid_utf8?(text) do
      GenServer.call(via(core, id), {:prompt, text})
    else
      {:error, :invalid_utf8}
    end
  end

  @doc """
  Steers the running turn. The text joins the queued steers and is delivered
  before the next provider call inside the turn. With no turn running it
  starts a turn, like a prompt. The text must be valid UTF-8. A full queue
  returns `{:error, :queue_full}`.
  """
  @spec steer(t(), String.t()) :: :ok | {:error, :invalid_utf8 | :queue_full}
  def steer(%__MODULE__{id: id, core: core}, text) when is_binary(text) do
    if Message.valid_utf8?(text) do
      GenServer.call(via(core, id), {:steer, text})
    else
      {:error, :invalid_utf8}
    end
  end

  @doc """
  Queues a follow-up prompt. It starts a new turn after the current turn ends
  normally. With no turn running it starts a turn at once. The text must be
  valid UTF-8. A full queue returns `{:error, :queue_full}`.
  """
  @spec follow_up(t(), String.t()) :: :ok | {:error, :invalid_utf8 | :queue_full}
  def follow_up(%__MODULE__{id: id, core: core}, text) when is_binary(text) do
    if Message.valid_utf8?(text) do
      GenServer.call(via(core, id), {:follow_up, text})
    else
      {:error, :invalid_utf8}
    end
  end

  @doc "Reads the queue counts, as in the `:queue_update` event."
  @spec queue_count(t()) :: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
  def queue_count(%__MODULE__{id: id, core: core}) do
    GenServer.call(via(core, id), :queue_count)
  end

  @doc "The session's current model ref, as a `provider/model` string."
  @spec model(t()) :: String.t()
  def model(%__MODULE__{id: id, core: core}) do
    GenServer.call(via(core, id), :model)
  end

  @doc """
  Switches the session's model. The ref is parsed and its provider resolved
  like the `:model` of `start/2`; a bad ref, an unknown provider, or a
  provider id that two plugins share is an error and the model stays as it
  was. The switch is written to the session
  file as a `model_change` entry, so a resume restores it, and goes out as a
  `:model_change` event. A running turn keeps the model it started with; the
  next turn uses the new one.
  """
  @spec set_model(t(), String.t()) ::
          :ok
          | {:error,
             {:invalid_model_ref, String.t()}
             | {:unknown_provider, String.t()}
             | {:ambiguous_provider, String.t()}
             | {:bad_provider_turn, String.t()}}
  def set_model(%__MODULE__{id: id, core: core}, string) when is_binary(string) do
    with {:ok, {ref, provider, turn_mode}} <- resolve_model(core, string) do
      GenServer.call(via(core, id), {:set_model, ref, provider, turn_mode})
    end
  end

  @doc """
  Aborts the running turn. Returns after the hands have killed every process
  the turn started, so a prompt sent next starts on a clean working
  directory. Each tool call without a result gets an `aborted` error result,
  so the transcript keeps complete call and result pairs. The events of the
  abort go out at once, before the hands are done; only this call waits. With
  no turn running and no abort in progress this is a no-op.
  """
  @spec abort(t()) :: :ok
  def abort(%__MODULE__{id: id, core: core}) do
    GenServer.call(via(core, id), :abort, :infinity)
  end

  @doc false
  def start_link(%State{id: id, core: core} = state) do
    GenServer.start_link(__MODULE__, state, name: via(core, id))
  end

  # Callbacks

  @impl true
  def init(%State{} = state) do
    # The session traps exits: the hands and the provider Task are linked,
    # so their crashes arrive as messages, and a death of the session takes
    # both with it (ADR 0004).
    Process.flag(:trap_exit, true)

    case Helyx.Hands.start_link(core: state.core, cwd: state.cwd, session: self()) do
      {:ok, hands} ->
        state = %{state | hands: hands, tools: Helyx.Hands.tools(hands)}

        # A resumed transcript can end mid-turn, after a crash. Each open tool
        # call gets an `aborted` error result before anyone can subscribe, so
        # the next provider call sees complete call and result pairs.
        aborted =
          Enum.map(
            Transcript.open_calls(state.transcript),
            &Message.tool_result(&1, {:error, "aborted"})
          )

        {:ok, Enum.reduce(aborted, state, &append_message(&2, &1))}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # An abort waits for the hands. A turn that starts now could send a tool
  # call to the hands during their release, and that call would block the
  # session, so every message queues until the hands answer.
  @impl true
  def handle_call({:steer, text}, _from, %State{aborting: {_request, _callers}} = state) do
    queue_reply(state, :steers, text)
  end

  def handle_call({op, text}, _from, %State{aborting: {_request, _callers}} = state)
      when op in [:prompt, :follow_up] do
    queue_reply(state, :follow_ups, text)
  end

  # An abort drops the queues, like the abort that started the wait, so no
  # message sent before it starts a turn.
  def handle_call(:abort, from, %State{aborting: {request, callers}} = state) do
    {:noreply, %{drop_queues(state) | aborting: {request, [from | callers]}}}
  end

  def handle_call({:prompt, _text}, _from, %State{turn: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  # An external turn takes no message inside its call: the steer aborts it,
  # and the queues start the next one when the hands answer.
  def handle_call({:steer, text}, _from, %State{turn: %Turn{} = turn} = state) do
    case {queue_reply(state, :steers, text), turn.turn_mode} do
      {{:reply, :ok, state}, :external} -> {:reply, :ok, abort_turn(state, [], & &1)}
      {reply, _turn_mode} -> reply
    end
  end

  def handle_call({:follow_up, text}, _from, %State{turn: %Turn{}} = state) do
    queue_reply(state, :follow_ups, text)
  end

  def handle_call({op, text}, _from, %State{} = state)
      when op in [:prompt, :steer, :follow_up] do
    {:reply, :ok, begin_turn(state, [text])}
  end

  def handle_call(:queue_count, _from, %State{} = state) do
    {:reply, Queues.counts(state.queues), state}
  end

  def handle_call(:model, _from, %State{model: ref} = state) do
    {:reply, ModelRef.to_string(ref), state}
  end

  def handle_call({:set_model, %ModelRef{} = ref, provider, turn_mode}, _from, %State{} = state) do
    model = ModelRef.to_string(ref)
    file = persist(state.file, &SessionFile.append_model_change(&1, model))
    state = %{state | model: ref, provider: provider, turn_mode: turn_mode, file: file}
    {:reply, :ok, do_emit(state, nil, :model_change, %{model: model})}
  end

  def handle_call(:abort, _from, %State{turn: nil} = state), do: {:reply, :ok, state}

  # The release of the hands can take longer than the timeout of a client call
  # (issue #93), so the session does not wait in a call: the answer of the
  # hands arrives as a message, and the abort callers get their reply then.
  def handle_call(:abort, from, %State{turn: %Turn{}} = state) do
    {:noreply, abort_turn(state, [from], &drop_queues/1)}
  end

  @impl true
  def handle_info(
        {:stream_event, turn_id, {:message_end, stop_reason, usage}},
        %State{turn: %Turn{id: turn_id}} = state
      ) do
    {state, _assistant, calls} = close_assistant(state, stop_reason, usage)
    state = Enum.reduce(calls, state, &emit(&2, :tool_execution_start, %{tool_call: &1}))
    %State{turn: turn} = state
    {:noreply, %{state | turn: %{turn | partial: nil, calls: calls}}}
  end

  # A result for a call of no completed message, or for a call that a
  # later message already closed, is dropped. A result goes
  # to the first open call with its id, the rule of `open_calls/1`, so the
  # transcript, the file, and the replay agree.
  def handle_info(
        {:stream_event, turn_id, {:tool_result, call_id, result}},
        %State{turn: %Turn{id: turn_id} = turn} = state
      ) do
    case Enum.find(turn.calls, &(&1.id == call_id)) do
      nil ->
        {:noreply, state}

      call ->
        state = %{state | turn: %{turn | calls: List.delete(turn.calls, call)}}
        {:noreply, record_result(call, result, state)}
    end
  end

  def handle_info(
        {:stream_event, turn_id, {:harness_session, id, cut}},
        %State{turn: %Turn{id: turn_id} = turn} = state
      ) do
    # The provider id is the prefix of the turn's model ref: `find/2`
    # matched it, so the session runs no plugin code for it.
    provider = turn.model.provider
    file = persist(state.file, &SessionFile.append_harness_session(&1, provider, id))
    sessions = Map.put(state.harness_sessions, provider, {id, length(state.transcript)})
    state = %{state | file: file, harness_sessions: sessions}
    data = %{provider: provider, harness_session_id: id, lost: turn.resumed != nil, cut: cut}
    {:noreply, emit(state, :harness_session, data)}
  end

  def handle_info({:stream_event, turn_id, event}, %State{turn: %Turn{id: turn_id}} = state) do
    %State{turn: turn} = state = start_assistant_message(state)

    {:noreply,
     %{state | turn: Turn.add_block(turn, event)}
     |> emit(:message_update, Map.new([event]))}
  end

  # Arrives before the stream event of the call it names (see
  # `Helyx.Session.Stream`).
  def handle_info({:rejected_call, turn_id, call}, %State{turn: %Turn{id: turn_id}} = state) do
    %State{turn: turn} = state
    {:noreply, %{state | turn: Turn.reject(turn, call)}}
  end

  # The Task's reply is the terminal stream event. Its :DOWN follows and is
  # flushed here, so a :DOWN only reaches the session when the Task crashed.
  def handle_info({ref, terminal}, %State{turn: %Turn{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, end_turn(terminal, state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{turn: %Turn{task: %Task{ref: ref}}} = state
      ) do
    {:noreply, fail_turn({:task_exit, Message.cap_integers(reason)}, state)}
  end

  # The terminal of an external turn's stream, from the hands after the release.
  def handle_info({:stream_end, turn_id, terminal}, %State{turn: %Turn{id: turn_id}} = state) do
    {:noreply, end_turn(Message.cap_integers(terminal), state)}
  end

  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{
          turn: %Turn{id: turn_id, calls: [%Message.ToolCall{id: call_id} = call | rest]} = turn
        } =
          state
      ) do
    state = record_result(call, result, %{state | turn: %{turn | calls: rest}})

    case rest do
      [] -> {:noreply, start_provider_call(state)}
      [next | _] -> {:noreply, run_tool(next, state)}
    end
  end

  # A message for a turn, or a call, that is no longer current.
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}
  def handle_info({:stream_end, _turn_id, _terminal}, state), do: {:noreply, state}
  def handle_info({:rejected_call, _turn_id, _call}, state), do: {:noreply, state}

  # The hands are linked and vital: their death takes the session with it.
  def handle_info({:EXIT, pid, reason}, %State{hands: pid} = state) do
    {:stop, reason, state}
  end

  # A provider Task's exit signal is expected; its reply or :DOWN carries
  # the outcome. An exit from any other linked process, the sessions
  # Registry for example, is vital: a session that outlived its registration
  # would keep working where no client can reach it. A pid whose exit was
  # consumed by Task.shutdown on abort stays in the set, because a late exit
  # signal for it can still arrive; the set grows by one pid per abort.
  def handle_info({:EXIT, pid, reason}, %State{provider_pids: pids} = state) do
    if MapSet.member?(pids, pid) do
      {:noreply, %{state | provider_pids: MapSet.delete(pids, pid)}}
    else
      {:stop, reason, state}
    end
  end

  # The answer of the hands to the cancel request of an abort. The hands are
  # vital, so a request that fails because they died stops the session, like
  # their exit signal.
  def handle_info(message, %State{aborting: {request, callers}} = state) do
    case Helyx.Hands.cancel_response(message, request) do
      :no_reply ->
        drop_unknown(message, state)

      {:reply, result} ->
        with {:error, reason} <- result, do: Logger.warning("abort cleanup failed: " <> reason)
        Enum.each(callers, &GenServer.reply(&1, :ok))
        {:noreply, start_queued(%{state | aborting: nil})}

      {:error, {reason, _hands}} ->
        {:stop, reason, state}
    end
  end

  # The last clause, for every state: a late reply of a call that timed out,
  # or a stray monitor message.
  def handle_info(message, %State{} = state), do: drop_unknown(message, state)

  # The one place that drops an unknown message, with one log line.
  defp drop_unknown(message, state) do
    Logger.warning("dropped an unknown message: " <> shape(message))
    {:noreply, state}
  end

  # The log text for a dropped message. It names the shape and never formats
  # the message, so its size does not depend on the message: an atom has at
  # most 255 characters. It reads the first element by index because the size
  # of the tuple is not known, and the value goes only to the log text.
  defp shape(message) when is_atom(message), do: "the atom " <> inspect(message)

  defp shape(message)
       when is_tuple(message) and tuple_size(message) > 0 and is_atom(elem(message, 0)),
       do: "a tuple of size #{tuple_size(message)} with the tag #{inspect(elem(message, 0))}"

  defp shape(message) when is_tuple(message), do: "a tuple of size #{tuple_size(message)}"
  defp shape(_message), do: "not an atom and not a tuple"

  # The session stops only for a trapped reason; on an untrappable kill the
  # link kills the provider Task, and the hands take the tool Tasks.
  @impl true
  def terminate(_reason, %State{turn: %Turn{task: %Task{} = task}}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Turn machinery

  # Ends the turn at once and asks the hands to release its resources; the
  # `callers` get their reply when the hands answer. `queues` drops the
  # queues for an abort and keeps them for the steer of an external turn.
  defp abort_turn(%State{turn: turn} = state, callers, queues) do
    if turn.task, do: Task.shutdown(turn.task, :brutal_kill)
    request = Helyx.Hands.request_cancel(state.hands, turn.id)

    state =
      state
      |> abort_open_calls()
      |> close_partial_message(:aborted, :aborted)
      |> queues.()
      |> emit(:agent_end, %{stop_reason: :aborted})
      |> close_turn()

    %{state | aborting: {request, callers}}
  end

  # Starts a turn with one user message per text, in order.
  defp begin_turn(%State{} = state, texts) do
    turn = %Turn{
      id: Helyx.Id.new(),
      model: state.model,
      provider: state.provider,
      turn_mode: state.turn_mode
    }

    state = %{state | turn: turn}
    state = state |> emit(:agent_start, %{}) |> emit(:turn_start, %{})
    start_provider_call(Enum.reduce(texts, state, &append_user(&2, &1)))
  end

  defp append_user(state, text) do
    user = Message.user(text)

    append_message(state, user)
    |> emit(:message_start, %{message: user})
    |> emit(:message_end, %{message: user})
  end

  defp queue_reply(%State{} = state, key, text) do
    case Queues.push(state.queues, key, text) do
      {:ok, queues} -> {:reply, :ok, emit_queue(%{state | queues: queues})}
      {:error, :queue_full} = error -> {:reply, error, state}
    end
  end

  defp emit_queue(%State{} = state), do: emit(state, :queue_update, Queues.counts(state.queues))

  defp drop_queues(%State{queues: queues} = state) do
    case Queues.clear(queues) do
      ^queues -> state
      cleared -> emit_queue(%{state | queues: cleared})
    end
  end

  # A normal turn end starts a new turn with everything still queued, steers
  # first. The drain event goes out between the turns, with a nil turn id.
  defp start_queued(%State{} = state) do
    case Queues.drain(state.queues) do
      {[], _queues} ->
        state

      {texts, queues} ->
        %{state | queues: queues}
        |> emit_queue()
        |> begin_turn(texts)
    end
  end

  # Queued steers join the transcript before the provider call they precede.
  defp start_provider_call(%State{} = state) do
    case Queues.drain_steers(state.queues) do
      {[], _queues} ->
        call_provider(state)

      {steers, queues} ->
        Enum.reduce(steers, %{state | queues: queues}, &append_user(&2, &1))
        |> emit_queue()
        |> call_provider()
    end
  end

  defp call_provider(%State{turn: %Turn{id: turn_id} = turn} = state) do
    external? = turn.turn_mode == :external

    resumed =
      if external?,
        do: Transcript.resumable(state.transcript, state.harness_sessions, turn.model.provider)

    opts = [core: state.core, session_id: state.id, turn_id: turn_id, cwd: state.cwd]
    opts = if external?, do: opts ++ [harness_session_id: resumed], else: opts

    args = %{
      model_context: state.model_context,
      compaction: state.compaction,
      provider: turn.provider,
      model: turn.model.model,
      context: %Context{messages: state.transcript, tools: state.tools},
      opts: opts,
      session: self(),
      turn_id: turn_id,
      external?: external?
    }

    run = fn -> Helyx.Session.Stream.run(args) end

    start_stream(turn.turn_mode, run, %{state | turn: %{turn | rejected: [], resumed: resumed}})
  end

  # The Task is linked: the session traps exits, so a crash stays a message,
  # and a death of the session kills the stream.
  defp start_stream(:local, run, %State{turn: turn} = state) do
    task = Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), run)

    %{
      state
      | turn: %{turn | task: task},
        provider_pids: MapSet.put(state.provider_pids, task.pid)
    }
  end

  # An external turn's stream is a Task of the hands (see the moduledoc).
  defp start_stream(:external, run, %State{turn: turn} = state) do
    :ok = Helyx.Hands.stream(state.hands, turn.id, turn.provider, run)
    state
  end

  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    {%State{turn: turn} = state, assistant, calls} = close_assistant(state, stop_reason, usage)

    case {calls, turn.turn_mode} do
      {[first | _], :local} ->
        run_tool(first, %{state | turn: %{turn | task: nil, partial: nil, calls: calls}})

      # A provider with an external turn ran its calls itself; one in the
      # last message gets no result.
      _no_calls_or_external ->
        state
        |> abort_open_calls()
        |> emit(:turn_end, %{message: assistant})
        |> emit(:agent_end, %{stop_reason: stop_reason})
        |> close_turn()
        |> start_queued()
    end
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # Appends the assistant message of the stream so far and emits its
  # message_end. Returns it and its tool calls. No message goes between a
  # call and its result: the calls still open (only an external turn has any
  # here) get their aborted results first, and a later result is dropped.
  defp close_assistant(%State{turn: turn} = state, stop_reason, usage) do
    state = put_in(state.turn.calls, [])
    state = Enum.reduce(turn.calls, state, &record_result(&1, {:error, "aborted"}, &2))
    state = start_assistant_message(state)
    assistant = Turn.assistant_message(state.turn, stop_reason: stop_reason, usage: usage)
    state = emit(append_message(state, assistant), :message_end, %{message: assistant})
    {state, assistant, for(%Message.ToolCall{} = call <- assistant.content, do: call)}
  end

  defp run_tool(call, %State{turn: turn} = state) do
    if Turn.rejected?(turn, call) do
      # The result takes the path of a result from the hands, so the events
      # and the order of the calls stay the same.
      send(self(), {:tool_result, turn.id, call.id, {:error, @rejected_call_text}})
    else
      :ok = Helyx.Hands.run(state.hands, turn.id, call)
    end

    emit(state, :tool_execution_start, %{tool_call: call})
  end

  # Appends the tool result message to the transcript and emits
  # tool_execution_end.
  defp record_result(call, result, state) do
    message = Message.tool_result(call, result)
    emit(append_message(state, message), :tool_execution_end, %{message: message})
  end

  # Appends a completed message to the transcript and, when the session has
  # a file, to disk. Streamed partial messages never come through here.
  defp append_message(%State{} = state, %Message{} = message) do
    file = persist(state.file, &SessionFile.append_message(&1, message))
    %{state | transcript: state.transcript ++ [message], file: file}
  end

  defp persist(nil, _append), do: nil

  defp persist(file, append) do
    append.(file)
  rescue
    # A disk failure must not take the session down. The turn, or the model
    # switch, goes on in memory; persistence stays off for this session. Only
    # the disk write is caught: a value the file cannot encode is rejected
    # at the stream boundary (see `Helyx.Session.Stream`), and a model ref by
    # `ModelRef.parse/1`, so an encode error here is a
    # bug and crashes loudly rather than silently losing the rest of the
    # session.
    error in File.Error ->
      Logger.warning("session file append failed, persistence off: " <> Exception.message(error))
      nil
  end

  # Each tool call without a result gets an `aborted` error result in the
  # transcript, so the next provider call sees a complete pair.
  defp abort_open_calls(%State{} = state) do
    Enum.reduce(
      Transcript.open_calls(state.transcript),
      state,
      &record_result(&1, {:error, "aborted"}, &2)
    )
  end

  # A partial assistant message is closed with a failure stop reason so
  # clients do not keep it open. It is not added to the transcript.
  # An external turn can fail after a message whose calls have no result yet.
  defp fail_turn(reason, state) do
    state
    |> abort_open_calls()
    |> close_partial_message(:error, reason)
    |> drop_queues()
    |> emit(:agent_end, %{stop_reason: :error, error: reason})
    |> close_turn()
  end

  defp close_partial_message(%State{turn: %Turn{partial: nil}} = state, _stop, _reason), do: state

  defp close_partial_message(state, stop_reason, reason) do
    emit(state, :message_end, %{
      message: Turn.assistant_message(state.turn, stop_reason: stop_reason),
      error: reason
    })
  end

  defp close_turn(%State{} = state), do: %{state | turn: nil}

  # Emits message_start for the assistant message on the first stream event.
  defp start_assistant_message(%State{turn: %Turn{partial: nil} = turn} = state) do
    state = %{state | turn: %{turn | partial: []}}
    emit(state, :message_start, %{message: Turn.assistant_message(state.turn, [])})
  end

  defp start_assistant_message(state), do: state

  # Only the queue drain at a normal turn end fires between turns; every
  # other emit with no turn is a bug and crashes here.
  defp emit(%State{turn: nil} = state, :queue_update, data),
    do: do_emit(state, nil, :queue_update, data)

  defp emit(%State{turn: %Turn{id: turn_id}} = state, type, data),
    do: do_emit(state, turn_id, type, data)

  defp do_emit(state, turn_id, type, data) do
    seq = state.seq + 1
    event = %Event{type: type, session_id: state.id, turn_id: turn_id, seq: seq, data: data}

    Registry.dispatch(Helyx.Core.events_registry(state.core), state.id, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:helyx_event, event})
    end)

    %{state | seq: seq}
  end

  defp via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
