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

  Consecutive deltas of one kind form one block. A tool call arrives whole;
  a provider that streams tool call arguments assembles them first. There is
  no image event: providers do not produce image blocks. A malformed event
  fails the turn with `{:bad_stream_event, event}`.

  `stop_reason` is the closed set `Helyx.SessionFile` owns: a provider
  normalizes whatever its wire protocol reports into it.

  The session calls `stream/3` with `opts` carrying `:core`, `:session_id`,
  and `:turn_id`, so a provider can scope state and label its calls.

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

  @callback id() :: String.t()
  @callback stream(model :: String.t(), context :: Helyx.Context.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
