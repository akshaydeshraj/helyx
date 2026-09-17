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
  The session monitors the Task. The Task sends each stream event to the
  session, which builds the assistant message and emits events. A stream must
  end with `{:done, _}` or `{:error, _}`. If the Task ends while the turn is
  still open, the session ends the turn with a `:stream_ended` error.
  """

  use GenServer

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
         {:ok, provider} <- Helyx.Core.provider(core, ref.provider) do
      id = new_id()
      args = %{id: id, core: core, model: ref, provider: provider}

      case DynamicSupervisor.start_child(Helyx.Core.session_supervisor(core), {__MODULE__, args}) do
        {:ok, _pid} -> {:ok, %__MODULE__{id: id, core: core}}
        {:error, reason} -> {:error, reason}
      end
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
  def prompt(%__MODULE__{} = session, text) when is_binary(text) do
    GenServer.call(via(session), {:prompt, text})
  end

  @doc false
  def child_spec(%{id: id} = args) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [args]}, restart: :temporary}
  end

  @doc false
  def start_link(%{id: id, core: core} = args) do
    GenServer.start_link(__MODULE__, args, name: via(%__MODULE__{id: id, core: core}))
  end

  # Callbacks

  @impl true
  def init(args) do
    {:ok, %State{id: args.id, core: args.core, model: args.model, provider: args.provider}}
  end

  @impl true
  def handle_call({:prompt, _text}, _from, %State{turn: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  def handle_call({:prompt, text}, _from, %State{} = state) do
    user = Message.user(text)

    state =
      %State{state | transcript: state.transcript ++ [user], turn: %Turn{id: new_id()}}
      |> emit(:agent_start, %{})
      |> emit(:turn_start, %{})
      |> emit(:message_start, %{message: user})
      |> emit(:message_end, %{message: user})
      |> start_provider_call()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:stream_event, turn_id, event}, %State{turn: %Turn{id: turn_id}} = state) do
    {:noreply, handle_stream_event(event, state)}
  end

  # A stream event from a turn that is no longer current is dropped.
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}

  # The current task finished. Its reply and its :DOWN both arrive; the reply
  # comes first. A task that finishes with the turn still open ended its
  # stream without a terminal event.
  def handle_info({ref, _result}, %State{turn: %Turn{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, fail_turn(:stream_ended, state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{turn: %Turn{task: %Task{ref: ref}}} = state
      ) do
    {:noreply, fail_turn({:task_exit, reason}, state)}
  end

  # Replies and :DOWN messages from a task that is no longer current are dropped.
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

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
          {:ok, stream} -> Enum.each(stream, &send(session, {:stream_event, turn_id, &1}))
          {:error, reason} -> send(session, {:stream_event, turn_id, {:error, reason}})
        end

        :ok
      end)

    %{state | turn: %{turn | task: task}}
  end

  defp handle_stream_event({:text_delta, delta}, state) do
    %State{turn: turn} = state = start_assistant_message(state)

    %{state | turn: %{turn | partial: turn.partial <> delta}}
    |> emit(:message_update, %{delta: delta})
  end

  defp handle_stream_event({:done, %{stop_reason: stop_reason} = meta}, state) do
    %State{turn: turn} = state = start_assistant_message(state)
    Process.demonitor(turn.task.ref, [:flush])

    assistant = %Message{
      role: :assistant,
      content: [%Message.Text{text: turn.partial}],
      model: ModelRef.to_string(state.model),
      stop_reason: stop_reason,
      usage: Map.get(meta, :usage, %{})
    }

    %{state | transcript: state.transcript ++ [assistant]}
    |> emit(:message_end, %{message: assistant})
    |> emit(:turn_end, %{message: assistant})
    |> emit(:agent_end, %{stop_reason: stop_reason})
    |> close_turn()
  end

  defp handle_stream_event({:error, reason}, state), do: fail_turn(reason, state)

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

  defp emit(%State{} = state, type, data) do
    seq = state.seq + 1

    event = %Event{
      type: type,
      session_id: state.id,
      turn_id: state.turn && state.turn.id,
      seq: seq,
      data: data
    }

    Registry.dispatch(Helyx.Core.events_registry(state.core), state.id, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:helyx_event, event})
    end)

    %{state | seq: seq}
  end

  defp via(%__MODULE__{id: id, core: core}) do
    {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
