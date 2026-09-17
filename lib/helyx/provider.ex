defmodule Helyx.Provider do
  @moduledoc """
  Produces assistant messages for a session.

  A provider plugin implements this behaviour. `id/0` is the prefix in a model
  ref such as `fake/echo`. `stream/3` returns an enumerable of stream events
  for one provider call:

    * `{:text_delta, binary}`: a chunk of assistant text
    * `{:done, %{stop_reason: atom, usage: map}}`: the call finished
    * `{:error, term}`: the call failed

  The session consumes the enumerable in a Task and builds the assistant
  message from the deltas. Consumption stops at the first `done` or `error`.
  A stream that ends without one fails the turn with `:stream_ended`. The
  turn's outcome is the Task's outcome: a stream that raises, including in
  its cleanup after `done`, fails the turn with `{:task_exit, reason}`.
  """

  use Helyx.Interface, mode: :multi, required: true

  @type stream_event ::
          {:text_delta, String.t()}
          | {:done, %{stop_reason: atom(), usage: map()}}
          | {:error, term()}

  @doc "Finds the provider plugin whose id matches a model ref prefix."
  @spec find(Helyx.Core.name(), String.t()) ::
          {:ok, module()} | {:error, {:unknown_provider, String.t()}}
  def find(core, id) do
    case Enum.find(Helyx.Core.plugins(core, __MODULE__), &(&1.id() == id)) do
      nil -> {:error, {:unknown_provider, id}}
      plugin -> {:ok, plugin}
    end
  end

  @callback id() :: String.t()
  @callback stream(model :: String.t(), context :: Helyx.Context.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
