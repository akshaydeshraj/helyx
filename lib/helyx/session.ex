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

  @queue_limit 32

  @rejected_call_text "tool call not run: an integer in the arguments has more than " <>
                        "#{Message.max_integer_digits()} digits"

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  defmodule Turn do
    @moduledoc false
    # The turn in progress. `partial` is the assistant content so far as a
    # reversed block list, or nil before the first stream event. `calls` are
    # the tool calls still to answer, the head running. `rejected` are the
    # tool calls of the current assistant message that get an error result
    # and never run, because their arguments held an integer over the digit
    # limit (see `Helyx.Message.cap_integers/1`). They are compared by value,
    # because a provider can repeat a call id: a call that is equal to a
    # rejected call after the cap is also rejected. One turn has many provider
    # calls, so each provider call starts with an empty list.
    # `model` and `provider` are fixed when the turn starts, so a model switch
    # during the turn takes effect on the next one.
    @enforce_keys [:id, :model, :provider]
    defstruct [:id, :model, :provider, :task, :partial, calls: [], rejected: []]
  end

  defmodule State do
    @moduledoc false
    @enforce_keys [:id, :core, :model, :provider, :cwd]
    defstruct [
      :id,
      :core,
      :model,
      :provider,
      :cwd,
      :hands,
      :file,
      tools: [],
      transcript: [],
      seq: 0,
      turn: nil,
      steers: [],
      follow_ups: [],
      provider_pids: MapSet.new(),
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
    with {:ok, {ref, provider}} <- resolve_model(core, Keyword.fetch!(opts, :model)),
         {:ok, _tools} <- Helyx.Tool.by_name(core),
         {:ok, file} <- create_file(opts[:sessions_dir], id, cwd, ref) do
      start_child(%State{
        id: id,
        core: core,
        model: ref,
        provider: provider,
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
         {:ok, {ref, provider}} <- resolve_model(core, resumed.model),
         {:ok, _tools} <- Helyx.Tool.by_name(core) do
      start_child(%State{
        id: resumed.session_id,
        core: core,
        model: ref,
        provider: provider,
        cwd: cwd,
        file: resumed.file,
        transcript: resumed.messages
      })
    end
  end

  # A model ref string to its parsed ref and its provider plugin, for start,
  # resume, and a switch alike.
  defp resolve_model(core, string) do
    with {:ok, ref} <- ModelRef.parse(string),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider) do
      {:ok, {ref, provider}}
    end
  end

  defp start_child(%State{id: id, core: core} = state) do
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
             | {:ambiguous_provider, String.t()}}
  def set_model(%__MODULE__{id: id, core: core}, string) when is_binary(string) do
    with {:ok, {ref, provider}} <- resolve_model(core, string) do
      GenServer.call(via(core, id), {:set_model, ref, provider})
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
          Enum.map(open_calls(state.transcript), &Message.tool_result(&1, {:error, "aborted"}))

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

  def handle_call({:steer, text}, _from, %State{turn: %Turn{}} = state) do
    queue_reply(state, :steers, text)
  end

  def handle_call({:follow_up, text}, _from, %State{turn: %Turn{}} = state) do
    queue_reply(state, :follow_ups, text)
  end

  def handle_call({op, text}, _from, %State{} = state)
      when op in [:prompt, :steer, :follow_up] do
    {:reply, :ok, begin_turn(state, [text])}
  end

  def handle_call(:queue_count, _from, %State{} = state) do
    {:reply, queue_counts(state), state}
  end

  def handle_call(:model, _from, %State{model: ref} = state) do
    {:reply, ModelRef.to_string(ref), state}
  end

  def handle_call({:set_model, %ModelRef{} = ref, provider}, _from, %State{} = state) do
    model = ModelRef.to_string(ref)
    file = persist(state.file, &SessionFile.append_model_change(&1, model))
    state = %{state | model: ref, provider: provider, file: file}
    {:reply, :ok, do_emit(state, nil, :model_change, %{model: model})}
  end

  def handle_call(:abort, _from, %State{turn: nil} = state), do: {:reply, :ok, state}

  # The release of the hands can take longer than the timeout of a client call
  # (issue #93), so the session does not wait in a call: the answer of the
  # hands arrives as a message, and the abort callers get their reply then.
  def handle_call(:abort, from, %State{turn: %Turn{} = turn} = state) do
    if turn.task, do: Task.shutdown(turn.task, :brutal_kill)
    request = Helyx.Hands.request_cancel(state.hands, turn.id)

    state =
      state
      |> abort_open_calls()
      |> close_partial_message(:aborted, :aborted)
      |> drop_queues()
      |> emit(:agent_end, %{stop_reason: :aborted})
      |> close_turn()

    {:noreply, %{state | aborting: {request, [from]}}}
  end

  @impl true
  def handle_info({:stream_event, turn_id, event}, %State{turn: %Turn{id: turn_id}} = state) do
    %State{turn: turn} = state = start_assistant_message(state)

    {:noreply,
     %{state | turn: %{turn | partial: Message.add_block(turn.partial, event)}}
     |> emit(:message_update, Map.new([event]))}
  end

  # Arrives before the stream event of the call it names (see consume/3).
  def handle_info({:rejected_call, turn_id, call}, %State{turn: %Turn{id: turn_id}} = state) do
    %State{turn: turn} = state
    {:noreply, %{state | turn: %{turn | rejected: [call | turn.rejected]}}}
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

  # Starts a turn with one user message per text, in order.
  defp begin_turn(%State{} = state, texts) do
    turn = %Turn{id: Helyx.Id.new(), model: state.model, provider: state.provider}
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

  defp queue_reply(%State{steers: steers} = state, :steers, text)
       when length(steers) < @queue_limit do
    {:reply, :ok, emit_queue(%{state | steers: steers ++ [text]})}
  end

  defp queue_reply(%State{follow_ups: follow_ups} = state, :follow_ups, text)
       when length(follow_ups) < @queue_limit do
    {:reply, :ok, emit_queue(%{state | follow_ups: follow_ups ++ [text]})}
  end

  defp queue_reply(%State{} = state, key, _text) when key in [:steers, :follow_ups],
    do: {:reply, {:error, :queue_full}, state}

  defp emit_queue(%State{} = state), do: emit(state, :queue_update, queue_counts(state))

  defp queue_counts(%State{steers: steers, follow_ups: follow_ups}) do
    %{steers: length(steers), follow_ups: length(follow_ups)}
  end

  defp drop_queues(%State{steers: [], follow_ups: []} = state), do: state
  defp drop_queues(%State{} = state), do: emit_queue(%{state | steers: [], follow_ups: []})

  # A normal turn end starts a new turn with everything still queued, steers
  # first. The drain event goes out between the turns, with a nil turn id.
  defp start_queued(%State{steers: [], follow_ups: []} = state), do: state

  defp start_queued(%State{steers: steers, follow_ups: follow_ups} = state) do
    %{state | steers: [], follow_ups: []}
    |> emit_queue()
    |> begin_turn(steers ++ follow_ups)
  end

  # Queued steers join the transcript before the provider call they precede.
  defp start_provider_call(%State{steers: [_ | _] = steers} = state) do
    state = Enum.reduce(steers, %{state | steers: []}, &append_user(&2, &1))
    start_provider_call(emit_queue(state))
  end

  defp start_provider_call(%State{turn: %Turn{id: turn_id} = turn} = state) do
    session = self()
    core = state.core
    provider = turn.provider
    model = turn.model.model
    base = %Context{messages: state.transcript, tools: state.tools}
    opts = [core: core, session_id: state.id, turn_id: turn_id, cwd: state.cwd]

    # Context building runs inside the Task so plugin code never blocks the
    # session and a plugin that raises fails the turn, not the session. The
    # Task is linked: the session traps exits, so a crash stays a message,
    # and a death of the session kills the stream.
    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(core), fn ->
        context = Helyx.ModelContext.build(core, base, opts)
        context = Helyx.Compaction.compact(core, context, opts)

        result =
          case provider.stream(model, context, opts) do
            {:ok, stream} -> consume(stream, session, turn_id)
            {:error, reason} -> {:error, reason}
          end

        # Every terminal leaves the Task through this cap, so no error reason
        # and no malformed event in one brings an integer over the digit
        # limit to the session (see `Helyx.Message.cap_integers/1`). A raise
        # or an exit is not a terminal: the `:DOWN` handler caps its reason.
        Message.cap_integers(result)
      end)

    %{
      state
      | turn: %{turn | task: task, rejected: []},
        provider_pids: MapSet.put(state.provider_pids, task.pid)
    }
  end

  # Forwards well-formed stream events to the session and returns the first
  # terminal event. A malformed event is a terminal error. Arguments or a
  # usage that are a struct are malformed: `cap_integers/1` can turn a struct
  # into a string, and the session file needs a plain map. A delta or a
  # tool call that is not valid UTF-8 is malformed: transcript text is
  # valid from the moment it exists, so the file and the providers never
  # see raw bytes.
  defp consume(stream, session, turn_id) do
    Enum.reduce_while(stream, :stream_ended, fn
      {kind, payload} = event, acc
      when kind in [:text_delta, :thinking_delta] and is_binary(payload) ->
        forward(Message.valid_utf8?(payload), event, session, turn_id, acc)

      {:tool_call, %Message.ToolCall{id: id, name: name, arguments: args}}, acc
      when is_binary(id) and is_binary(name) and is_non_struct_map(args) ->
        # The one place where tool call arguments enter the session from a
        # provider (on resume, SessionFile applies the same function). An
        # integer over the digit limit is replaced here, before the first
        # JSON encode, which is quadratic in the digits (#79). The
        # transcript, the events, the session file, the tool, and the next
        # provider request thus never hold it.
        capped = Message.cap_integers(args)
        # A new struct: the pattern also matches a call with one more key.
        call = %Message.ToolCall{id: id, name: name, arguments: capped}
        if capped != args, do: send(session, {:rejected_call, turn_id, call})
        forward(Message.encodable?([id, name, capped]), {:tool_call, call}, session, turn_id, acc)

      # The file format owns the closed stop reason set (see SessionFile) and
      # holds only JSON. A terminal whose stop reason is outside the set, or
      # whose usage the file cannot encode, fails the turn here, before the
      # message exists, instead of raising in persist and silently turning
      # persistence off for the rest of the session.
      {:done, %{stop_reason: reason, usage: usage}}, _acc
      when reason in [:end_turn, :tool_use, :max_tokens] and is_non_struct_map(usage) ->
        # The usage gets the same encodes as the arguments, so the same cap.
        usage = Message.cap_integers(usage)
        # A new plain map: the pattern also matches a struct and a map with
        # more keys, and `end_turn/2` needs this shape after the cap at the
        # Task exit.
        terminal = {:done, %{stop_reason: reason, usage: usage}}

        {:halt,
         if(Message.encodable?(usage),
           do: terminal,
           else: {:error, {:bad_stream_event, terminal}}
         )}

      {:error, _} = terminal, _acc ->
        {:halt, terminal}

      other, _acc ->
        {:halt, {:error, {:bad_stream_event, other}}}
    end)
  end

  defp forward(true = _valid, event, session, turn_id, acc) do
    send(session, {:stream_event, turn_id, event})
    {:cont, acc}
  end

  defp forward(false = _valid, event, _session, _turn_id, _acc),
    do: {:halt, {:error, {:bad_stream_event, event}}}

  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    %State{turn: turn} = state = start_assistant_message(state)
    assistant = assistant_message(state, stop_reason: stop_reason, usage: usage)

    state = emit(append_message(state, assistant), :message_end, %{message: assistant})

    calls = for %Message.ToolCall{} = call <- assistant.content, do: call

    case calls do
      [] ->
        state
        |> emit(:turn_end, %{message: assistant})
        |> emit(:agent_end, %{stop_reason: stop_reason})
        |> close_turn()
        |> start_queued()

      [first | _] = calls ->
        run_tool(first, %{state | turn: %{turn | task: nil, partial: nil, calls: calls}})
    end
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  defp run_tool(call, %State{turn: turn} = state) do
    if call in turn.rejected do
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
    # at the stream boundary (see consume/3), and a model ref by
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
    Enum.reduce(open_calls(state.transcript), state, &record_result(&1, {:error, "aborted"}, &2))
  end

  # The tool calls in the transcript that have no tool result yet, in call
  # order. During a turn this is exactly the calls still to answer; on a
  # transcript restored after a crash it is the calls the crash orphaned.
  # A result answers the first still-open earlier call with its id, so a
  # call id a provider reuses in a later turn stays open until its own
  # result arrives.
  defp open_calls(transcript) do
    Enum.reduce(transcript, [], fn
      %Message{role: :assistant, content: content}, open ->
        open ++ for %Message.ToolCall{} = call <- content, do: call

      %Message{role: :tool_result, tool_call_id: id}, open ->
        # Deleting nil is a no-op, so a result with no open call changes
        # nothing.
        List.delete(open, Enum.find(open, &(&1.id == id)))

      _message, open ->
        open
    end)
  end

  # A partial assistant message is closed with a failure stop reason so
  # clients do not keep it open. It is not added to the transcript.
  defp fail_turn(reason, state) do
    state
    |> close_partial_message(:error, reason)
    |> drop_queues()
    |> emit(:agent_end, %{stop_reason: :error, error: reason})
    |> close_turn()
  end

  defp close_partial_message(%State{turn: %Turn{partial: nil}} = state, _stop, _reason), do: state

  defp close_partial_message(state, stop_reason, reason) do
    emit(state, :message_end, %{
      message: assistant_message(state, stop_reason: stop_reason),
      error: reason
    })
  end

  # The assistant message for the current turn, from the blocks so far.
  defp assistant_message(%State{turn: %Turn{partial: partial, model: model}}, fields) do
    struct!(
      %Message{
        role: :assistant,
        content: Enum.reverse(partial),
        model: ModelRef.to_string(model)
      },
      fields
    )
  end

  defp close_turn(%State{} = state), do: %{state | turn: nil}

  # Emits message_start for the assistant message on the first stream event.
  defp start_assistant_message(%State{turn: %Turn{partial: nil} = turn} = state) do
    state = %{state | turn: %{turn | partial: []}}
    emit(state, :message_start, %{message: assistant_message(state, [])})
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
