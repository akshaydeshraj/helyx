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
  message from the deltas.
  """

  use Helyx.Interface, mode: :multi, required: true

  @type stream_event ::
          {:text_delta, String.t()}
          | {:done, %{stop_reason: atom(), usage: map()}}
          | {:error, term()}

  @callback id() :: String.t()
  @callback stream(model :: String.t(), context :: Helyx.Context.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
