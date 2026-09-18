defmodule Helyx.Session do
  @moduledoc """
  One conversation with one agent.

  A session is a supervised process under Core. It owns the transcript and
  the current turn. Clients subscribe to its events and send prompts.

      {:ok, session} = Helyx.Session.start(core, model: "fake/echo")
      :ok = Helyx.Session.subscribe(session)
      :ok = Helyx.Session.prompt(session, "hello")
      # receive {:helyx_event, %Helyx.Event{}} ...

  Each turn runs the provider stream in a Task under Core's task supervisor.
  The Task sends each stream event to the session and returns the terminal
  stream event, `done` or `error`. The session builds the assistant message
  from the stream events and closes the provider call on the Task's reply. A
  stream that ends without a terminal event, or a Task that crashes, fails
  the turn.

  An assistant message with tool calls runs them on the session's hands
  (`Helyx.Hands`) one at a time, in call order, so two calls never touch the
  working directory at once. Each result joins the transcript as it arrives,
  and the provider is called again after the last one. The turn ends on an
  assistant message with no tool calls.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Helyx.{Context, Event, Message, ModelRef, SessionFile}

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  defmodule Turn do
    @moduledoc false
    # The turn in progress. `partial` is the assistant content so far as a
    # reversed block list, or nil before the first stream event. `calls` are
    # the tool calls still to answer, the head running.
    @enforce_keys [:id]
    defstruct [:id, :task, :partial, calls: []]
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
      turn: nil
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
    with {:ok, ref} <- ModelRef.parse(Keyword.fetch!(opts, :model)),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
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
         {:ok, ref} <- ModelRef.parse(resumed.model),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
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

  @doc "Sends a prompt. Starts a turn if none is running. The text must be valid UTF-8."
  @spec prompt(t(), String.t()) :: :ok | {:error, :turn_running | :invalid_utf8}
  def prompt(%__MODULE__{id: id, core: core}, text) when is_binary(text) do
    if Message.valid_utf8?(text) do
      GenServer.call(via(core, id), {:prompt, text})
    else
      {:error, :invalid_utf8}
    end
  end

  @doc """
  Aborts the running turn. Returns after the hands have killed every process
  the turn started, so a prompt sent next starts on a clean working
  directory. Each tool call without a result gets an `aborted` error result,
  so the transcript keeps complete call and result pairs. With no turn
  running this is a no-op.
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
    {:ok, hands} = Helyx.Hands.start_link(core: state.core, cwd: state.cwd, session: self())
    state = %{state | hands: hands, tools: Helyx.Hands.tools(hands)}

    # A resumed transcript can end mid-turn, after a crash. Each open tool
    # call gets an `aborted` error result before anyone can subscribe, so
    # the next provider call sees complete call and result pairs.
    aborted =
      Enum.map(open_calls(state.transcript), &Message.tool_result(&1, {:error, "aborted"}))

    {:ok, Enum.reduce(aborted, state, &append_message(&2, &1))}
  end

  @impl true
  def handle_call({:prompt, _text}, _from, %State{turn: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  def handle_call({:prompt, text}, _from, %State{} = state) do
    user = Message.user(text)

    state =
      %{append_message(state, user) | turn: %Turn{id: Helyx.Id.new()}}
      |> emit(:agent_start, %{})
      |> emit(:turn_start, %{})
      |> emit(:message_start, %{message: user})
      |> emit(:message_end, %{message: user})
      |> start_provider_call()

    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, %State{turn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:abort, _from, %State{turn: %Turn{} = turn} = state) do
    if turn.task, do: Task.shutdown(turn.task, :brutal_kill)
    :ok = Helyx.Hands.cancel(state.hands, turn.id)

    state =
      state
      |> abort_open_calls()
      |> close_partial_message(:aborted, :aborted)
      |> emit(:agent_end, %{stop_reason: :aborted})
      |> close_turn()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:stream_event, turn_id, event}, %State{turn: %Turn{id: turn_id}} = state) do
    %State{turn: turn} = state = start_assistant_message(state)

    {:noreply,
     %{state | turn: %{turn | partial: add_block(event, turn.partial)}}
     |> emit(:message_update, Map.new([event]))}
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
    {:noreply, fail_turn({:task_exit, reason}, state)}
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

  # Turn machinery

  defp start_provider_call(%State{turn: %Turn{id: turn_id} = turn} = state) do
    session = self()
    core = state.core
    provider = state.provider
    model = state.model.model
    base = %Context{messages: state.transcript, tools: state.tools}
    opts = [core: core, session_id: state.id, turn_id: turn_id, cwd: state.cwd]

    # Context building runs inside the Task so plugin code never blocks the
    # session and a plugin that raises fails the turn, not the session.
    task =
      Task.Supervisor.async_nolink(Helyx.Core.task_supervisor(core), fn ->
        context = Helyx.ModelContext.build(core, base, opts)
        context = Helyx.Compaction.compact(core, context, opts)

        case provider.stream(model, context, opts) do
          {:ok, stream} -> consume(stream, session, turn_id)
          {:error, reason} -> {:error, reason}
        end
      end)

    %{state | turn: %{turn | task: task}}
  end

  # Forwards well-formed stream events to the session and returns the first
  # terminal event. A malformed event is a terminal error. A delta or a
  # tool call that is not valid UTF-8 is malformed: transcript text is
  # valid from the moment it exists, so the file and the providers never
  # see raw bytes.
  defp consume(stream, session, turn_id) do
    Enum.reduce_while(stream, :stream_ended, fn
      {kind, payload} = event, acc
      when kind in [:text_delta, :thinking_delta] and is_binary(payload) ->
        forward(Message.valid_utf8?(payload), event, session, turn_id, acc)

      {:tool_call, %Message.ToolCall{id: id, name: name, arguments: args}} = event, acc
      when is_binary(id) and is_binary(name) and is_map(args) ->
        forward(Message.valid_utf8?([id, name, args]), event, session, turn_id, acc)

      {:done, %{stop_reason: _, usage: _}} = terminal, _acc ->
        {:halt, terminal}

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

  # Consecutive deltas of one kind extend the head block; anything else
  # starts a new block. The list is reversed.
  defp add_block({:text_delta, d}, [%Message.Text{text: t} = b | rest]),
    do: [%{b | text: t <> d} | rest]

  defp add_block({:text_delta, d}, blocks), do: [%Message.Text{text: d} | blocks]

  defp add_block({:thinking_delta, d}, [%Message.Thinking{thinking: t} = b | rest]),
    do: [%{b | thinking: t <> d} | rest]

  defp add_block({:thinking_delta, d}, blocks), do: [%Message.Thinking{thinking: d} | blocks]
  defp add_block({:tool_call, call}, blocks), do: [call | blocks]

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

      [first | _] = calls ->
        run_tool(first, %{state | turn: %{turn | task: nil, partial: nil, calls: calls}})
    end
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  defp run_tool(call, %State{turn: turn} = state) do
    :ok = Helyx.Hands.run(state.hands, turn.id, call)
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
    %{state | transcript: state.transcript ++ [message], file: persist(state.file, message)}
  end

  defp persist(nil, _message), do: nil

  defp persist(file, message) do
    SessionFile.append_message(file, message)
  rescue
    # A disk failure must not take the session down. The turn goes on with
    # the in-memory transcript; persistence stays off for this session.
    error ->
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
  defp open_calls(transcript) do
    answered =
      for %Message{role: :tool_result} = m <- transcript, into: MapSet.new(), do: m.tool_call_id

    for %Message{role: :assistant, content: content} <- transcript,
        %Message.ToolCall{} = call <- content,
        call.id not in answered,
        do: call
  end

  # A partial assistant message is closed with a failure stop reason so
  # clients do not keep it open. It is not added to the transcript.
  defp fail_turn(reason, state) do
    state
    |> close_partial_message(:error, reason)
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
  defp assistant_message(%State{turn: %Turn{partial: partial}} = state, fields) do
    struct!(
      %Message{
        role: :assistant,
        content: Enum.reverse(partial),
        model: ModelRef.to_string(state.model)
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

  defp emit(%State{turn: %Turn{id: turn_id}} = state, type, data) do
    seq = state.seq + 1
    event = %Event{type: type, session_id: state.id, turn_id: turn_id, seq: seq, data: data}

    Registry.dispatch(Helyx.Core.events_registry(state.core), state.id, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:helyx_event, event})
    end)

    %{state | seq: seq}
  end

  defp via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
