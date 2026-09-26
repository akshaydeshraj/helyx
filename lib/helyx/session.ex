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
  (`Helyx.Session.Hands`) one at a time, in call order, so two calls never touch the
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

  alias Helyx.{Message, ModelRef}
  alias Helyx.Session.{Id, Server}
  alias Helyx.Session.Server.State

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  # Public API

  @doc """
  Starts a session under Core. `:model` is required. `:cwd` defaults to the
  current directory. With `:sessions_dir` the session is written to disk as
  it runs, as JSON lines under `<sessions_dir>/<project>/<session>.jsonl`;
  without it nothing is persisted.
  """
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(core \\ Helyx.Core, opts) do
    id = Id.new()
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
    do: Helyx.Session.File.create(dir, id, cwd, ModelRef.to_string(ref))

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

    with {:ok, resumed} <- Helyx.Session.File.resume(dir, cwd),
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
           DynamicSupervisor.start_child(Helyx.Core.session_supervisor(core), {Server, state}) do
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
  def pid(%__MODULE__{id: id, core: core}), do: GenServer.whereis(Server.via(core, id))

  @doc """
  Sends a prompt. Starts a turn if none is running. The text must be valid
  UTF-8. While an abort waits for the hands, the prompt queues as a
  follow-up, and a full queue returns `{:error, :queue_full}`.
  """
  @spec prompt(t(), String.t()) :: :ok | {:error, :turn_running | :invalid_utf8 | :queue_full}
  def prompt(%__MODULE__{id: id, core: core}, text) when is_binary(text) do
    if Message.valid_utf8?(text) do
      GenServer.call(Server.via(core, id), {:prompt, text})
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
      GenServer.call(Server.via(core, id), {:steer, text})
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
      GenServer.call(Server.via(core, id), {:follow_up, text})
    else
      {:error, :invalid_utf8}
    end
  end

  @doc "Reads the queue counts, as in the `:queue_update` event."
  @spec queue_count(t()) :: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
  def queue_count(%__MODULE__{id: id, core: core}) do
    GenServer.call(Server.via(core, id), :queue_count)
  end

  @doc "The session's current model ref, as a `provider/model` string."
  @spec model(t()) :: String.t()
  def model(%__MODULE__{id: id, core: core}) do
    GenServer.call(Server.via(core, id), :model)
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
      GenServer.call(Server.via(core, id), {:set_model, ref, provider, turn_mode})
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
    GenServer.call(Server.via(core, id), :abort, :infinity)
  end
end
