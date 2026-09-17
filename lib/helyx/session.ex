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

  An assistant message with tool calls sends each call to the session's hands
  (`Helyx.Hands`). When every result is back, the results join the transcript
  in call order and the provider is called again. The turn ends on an
  assistant message with no tool calls.
  """

  use GenServer, restart: :temporary

  alias Helyx.{Context, Event, Message, ModelRef}

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  defmodule Turn do
    @moduledoc false
    # The turn in progress. `partial` is the assistant content so far as a
    # reversed block list, or nil before the first stream event. `calls` are
    # the tool calls in flight and `results` the tool result messages so far,
    # by call id.
    @enforce_keys [:id]
    defstruct [:id, :task, :partial, calls: [], results: %{}]
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
      tools: [],
      transcript: [],
      seq: 0,
      turn: nil
    ]
  end

  # Public API

  @doc "Starts a session under Core. `:model` is required. `:cwd` defaults to the current directory."
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(core \\ Helyx.Core, opts) do
    with {:ok, ref} <- ModelRef.parse(Keyword.fetch!(opts, :model)),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
         {:ok, _tools} <- Helyx.Tool.by_name(core),
         cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
         state = %State{id: new_id(), core: core, model: ref, provider: provider, cwd: cwd},
         {:ok, _pid} <-
           DynamicSupervisor.start_child(Helyx.Core.session_supervisor(core), {__MODULE__, state}) do
      {:ok, %__MODULE__{id: state.id, core: core}}
    end
  end

  @doc "Subscribes the caller to the session's events, delivered as `{:helyx_event, event}`."
  @spec subscribe(t()) :: :ok
  def subscribe(%__MODULE__{id: id, core: core}) do
    {:ok, _} = Registry.register(Helyx.Core.events_registry(core), id, nil)
    :ok
  end

  @doc "Sends a prompt. Starts a turn if none is running."
  @spec prompt(t(), String.t()) :: :ok | {:error, :turn_running}
  def prompt(%__MODULE__{id: id, core: core}, text) when is_binary(text) do
    GenServer.call(via(core, id), {:prompt, text})
  end

  @doc false
  def start_link(%State{id: id, core: core} = state) do
    GenServer.start_link(__MODULE__, state, name: via(core, id))
  end

  # Callbacks

  @impl true
  def init(%State{} = state) do
    {:ok, hands} = Helyx.Hands.start_link(core: state.core, cwd: state.cwd, session: self())
    {:ok, %{state | hands: hands, tools: Helyx.Hands.tools(hands)}}
  end

  @impl true
  def handle_call({:prompt, _text}, _from, %State{turn: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  def handle_call({:prompt, text}, _from, %State{} = state) do
    user = Message.user(text)

    state =
      %{state | transcript: state.transcript ++ [user], turn: %Turn{id: new_id()}}
      |> emit(:agent_start, %{})
      |> emit(:turn_start, %{})
      |> emit(:message_start, %{message: user})
      |> emit(:message_end, %{message: user})
      |> start_provider_call()

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
        %State{turn: %Turn{id: turn_id}} = state
      ) do
    %State{turn: turn} = state
    call = Enum.find(turn.calls, &(&1.id == call_id))
    message = Message.tool_result(call, result)
    results = Map.put(turn.results, call_id, message)

    state =
      emit(%{state | turn: %{turn | results: results}}, :tool_execution_end, %{message: message})

    if map_size(results) == length(turn.calls),
      do: {:noreply, continue_turn(state)},
      else: {:noreply, state}
  end

  # A message for a turn that is no longer current.
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}

  # Turn machinery

  defp start_provider_call(%State{turn: %Turn{id: turn_id} = turn} = state) do
    session = self()
    provider = state.provider
    model = state.model.model
    context = %Context{messages: state.transcript, tools: state.tools}
    opts = [core: state.core, session_id: state.id, turn_id: turn_id]

    task =
      Task.Supervisor.async_nolink(Helyx.Core.task_supervisor(state.core), fn ->
        case provider.stream(model, context, opts) do
          {:ok, stream} -> consume(stream, session, turn_id)
          {:error, reason} -> {:error, reason}
        end
      end)

    %{state | turn: %{turn | task: task}}
  end

  # Forwards well-formed stream events to the session and returns the first
  # terminal event. A malformed event is a terminal error.
  defp consume(stream, session, turn_id) do
    Enum.reduce_while(stream, :stream_ended, fn
      {kind, payload} = event, acc
      when kind in [:text_delta, :thinking_delta] and is_binary(payload) ->
        send(session, {:stream_event, turn_id, event})
        {:cont, acc}

      {:tool_call, %Message.ToolCall{id: id, name: name, arguments: args}} = event, acc
      when is_binary(id) and is_binary(name) and is_map(args) ->
        send(session, {:stream_event, turn_id, event})
        {:cont, acc}

      {:done, %{stop_reason: _, usage: _}} = terminal, _acc ->
        {:halt, terminal}

      {:error, _} = terminal, _acc ->
        {:halt, terminal}

      other, _acc ->
        {:halt, {:error, {:bad_stream_event, other}}}
    end)
  end

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
    state = start_assistant_message(state)
    assistant = assistant_message(state, stop_reason: stop_reason, usage: usage)
    calls = for %Message.ToolCall{} = call <- assistant.content, do: call

    case Enum.map(calls, & &1.id) -- Enum.uniq(Enum.map(calls, & &1.id)) do
      [dup | _] ->
        fail_turn({:duplicate_tool_call_id, dup}, state)

      [] ->
        state =
          emit(%{state | transcript: state.transcript ++ [assistant]}, :message_end, %{
            message: assistant
          })

        case calls do
          [] ->
            state
            |> emit(:turn_end, %{message: assistant})
            |> emit(:agent_end, %{stop_reason: stop_reason})
            |> close_turn()

          calls ->
            run_tools(calls, state)
        end
    end
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  defp run_tools(calls, %State{turn: turn} = state) do
    state = %{state | turn: %{turn | task: nil, partial: nil, calls: calls, results: %{}}}

    Enum.reduce(calls, state, fn call, state ->
      :ok = Helyx.Hands.run(state.hands, turn.id, call)
      emit(state, :tool_execution_start, %{tool_call: call})
    end)
  end

  # Every tool result is in: append them in call order and call the provider again.
  defp continue_turn(%State{turn: turn} = state) do
    results = Enum.map(turn.calls, &Map.fetch!(turn.results, &1.id))

    start_provider_call(%{state | transcript: state.transcript ++ results})
  end

  # A partial assistant message is closed with an error stop reason so clients
  # do not keep it open. It is not added to the transcript.
  defp fail_turn(reason, state) do
    state
    |> close_partial_message(reason)
    |> emit(:agent_end, %{stop_reason: :error, error: reason})
    |> close_turn()
  end

  defp close_partial_message(%State{turn: %Turn{partial: nil}} = state, _reason), do: state

  defp close_partial_message(state, reason) do
    emit(state, :message_end, %{
      message: assistant_message(state, stop_reason: :error),
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

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
