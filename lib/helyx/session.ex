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
  The Task sends each text delta to the session and returns the terminal
  stream event, `done` or `error`. The session builds the assistant message
  from the deltas and closes the turn on the Task's reply. A stream that ends
  without a terminal event, or a Task that crashes, fails the turn.
  """

  use GenServer, restart: :temporary

  alias Helyx.{Context, Event, Message, ModelRef}

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  defmodule Turn do
    @moduledoc false
    # The turn in progress. `partial` is the assistant text so far, or nil
    # before the first delta.
    @enforce_keys [:id]
    defstruct [:id, :task, :partial]
  end

  defmodule State do
    @moduledoc false
    @enforce_keys [:id, :core, :model, :provider]
    defstruct [:id, :core, :model, :provider, transcript: [], seq: 0, turn: nil]
  end

  # Public API

  @doc "Starts a session under Core. `:model` is required."
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(core \\ Helyx.Core, opts) do
    with {:ok, ref} <- ModelRef.parse(Keyword.fetch!(opts, :model)),
         {:ok, provider} <- Helyx.Provider.find(core, ref.provider),
         state = %State{id: new_id(), core: core, model: ref, provider: provider},
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
  def init(%State{} = state), do: {:ok, state}

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
  def handle_info({:text_delta, turn_id, delta}, %State{turn: %Turn{id: turn_id}} = state) do
    %State{turn: turn} = state = start_assistant_message(state)

    {:noreply,
     %{state | turn: %{turn | partial: turn.partial <> delta}}
     |> emit(:message_update, %{delta: delta})}
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

  # Turn machinery

  defp start_provider_call(%State{turn: %Turn{id: turn_id} = turn} = state) do
    session = self()
    provider = state.provider
    model = state.model.model
    context = %Context{messages: state.transcript}
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

  # Forwards deltas to the session and returns the first terminal event.
  defp consume(stream, session, turn_id) do
    Enum.reduce_while(stream, :stream_ended, fn
      {:text_delta, delta}, acc ->
        send(session, {:text_delta, turn_id, delta})
        {:cont, acc}

      terminal, _acc ->
        {:halt, terminal}
    end)
  end

  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    %State{turn: turn} = state = start_assistant_message(state)

    assistant = %Message{
      role: :assistant,
      content: [%Message.Text{text: turn.partial}],
      model: ModelRef.to_string(state.model),
      stop_reason: stop_reason,
      usage: usage
    }

    %{state | transcript: state.transcript ++ [assistant]}
    |> emit(:message_end, %{message: assistant})
    |> emit(:turn_end, %{message: assistant})
    |> emit(:agent_end, %{stop_reason: stop_reason})
    |> close_turn()
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  defp fail_turn(reason, state) do
    state
    |> emit(:agent_end, %{stop_reason: :error, error: reason})
    |> close_turn()
  end

  defp close_turn(%State{} = state), do: %{state | turn: nil}

  # Emits message_start for the assistant message on the first delta.
  defp start_assistant_message(%State{turn: %Turn{partial: nil} = turn} = state) do
    message = %Message{role: :assistant, content: [], model: ModelRef.to_string(state.model)}

    %{state | turn: %{turn | partial: ""}}
    |> emit(:message_start, %{message: message})
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
