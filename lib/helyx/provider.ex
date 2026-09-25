defmodule Helyx.Provider do
  @moduledoc """
  Produces assistant messages for a session.

  A provider plugin implements this behaviour. `id/0` is the prefix in a model
  ref such as `fake/echo`. `stream/3` returns an enumerable of stream events
  for one provider call:

    * `{:text_delta, binary}`: a delta of assistant text
    * `{:thinking_delta, binary}`: a delta of thinking text
    * `{:tool_call, Helyx.Message.ToolCall.t()}`: one complete tool call
    * `{:done, %{stop_reason: stop_reason, usage: map}}`: the call finished
    * `{:error, term}`: the call failed

  A harness provider (`kind/0` returns `:harness`, ADR 0002) runs its own
  loop and its own tools inside one call, so its stream can also carry:

    * `{:message_end, stop_reason, usage}`: the assistant message so far is
      complete; its tool calls ran inside the harness
    * `{:tool_result, call_id, {:ok | :error, binary}}`: the result of a
      tool call of a completed message; the session cuts the text like a
      tool result (`Helyx.Tool.truncate/2`, `:tail`)
    * `{:harness_session, id, cut}`: the call started a fresh harness
      session with this id; `cut` is the number of transcript messages the
      provider left out of what it sent to it

  Consecutive deltas of one kind form one block. A tool call arrives whole;
  a provider that streams tool call arguments assembles them first. There is
  no image event: providers do not produce image blocks. A malformed event
  fails the turn with `{:bad_stream_event, event}`.

  `stop_reason` is the closed set `Helyx.SessionFile` owns: a provider
  normalizes whatever its wire protocol reports into it.

  The session calls `stream/3` with `opts` carrying `:core`, `:session_id`,
  `:turn_id`, and `:cwd`, so a provider can scope state and label its calls.
  A harness provider also gets `:harness_session_id`: the id of the harness
  session to resume, or nil for a fresh one. The session passes the id of
  the provider's last `harness_session` only when the last assistant message
  of the transcript came from this provider, so a lost id or a switch from
  another provider gives nil.

  A harness provider's stream runs as a Task of the session's hands
  (`Helyx.Hands`), so it can hold the OS resources of its program with
  `Helyx.Tool.hold/1` and must then implement `release/3`, with the
  contract of `c:Helyx.Tool.release/3`. An abort returns only when the
  release has returned (ADR 0004).

  The session consumes the enumerable in a Task and builds the assistant
  message from the events. Consumption stops at the first `done` or `error`.
  A stream that ends without one fails the turn with `:stream_ended`. The
  turn's outcome is the Task's outcome: a stream that raises, including in
  its cleanup after `done`, fails the turn with `{:task_exit, reason}`.
  """

  use Helyx.Interface, mode: :multi, required: true

  @type stop_reason :: :end_turn | :tool_use | :max_tokens

  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call, Helyx.Message.ToolCall.t()}
          | {:done, %{stop_reason: stop_reason(), usage: map()}}
          | {:error, term()}
          | {:message_end, stop_reason(), map()}
          | {:tool_result, String.t(), {:ok | :error, String.t()}}
          | {:harness_session, String.t(), non_neg_integer()}

  @doc "Finds the provider plugin whose id matches a model ref prefix. Two matches is an error."
  @spec find(Helyx.Core.name(), String.t()) ::
          {:ok, module()}
          | {:error, {:unknown_provider, String.t()} | {:ambiguous_provider, String.t()}}
  def find(core, id) do
    case Enum.filter(Helyx.Core.plugins(core, __MODULE__), &(&1.id() == id)) do
      [plugin] -> {:ok, plugin}
      [] -> {:error, {:unknown_provider, id}}
      _ -> {:error, {:ambiguous_provider, id}}
    end
  end

  @doc """
  The kind of a provider plugin: `provider.kind()` when it is exported, else
  `:model`. A `kind/0` that raises, throws, exits, or returns another value than `:model` or
  `:harness` is an error. It is plugin code, so the session calls this in
  the caller of a start, a resume, or a switch, and keeps the result.
  """
  @spec kind(module()) :: {:ok, :model | :harness} | :error
  def kind(provider) do
    kind = if function_exported?(provider, :kind, 0), do: provider.kind(), else: :model
    if kind in [:model, :harness], do: {:ok, kind}, else: :error
  catch
    _class, _reason -> :error
  end

  @callback id() :: String.t()
  @callback kind() :: :model | :harness
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel | :retry,
              deadline :: integer()
            ) ::
              [term()]
  @callback stream(model :: String.t(), context :: Helyx.Context.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @optional_callbacks kind: 0, release: 3
end
