defmodule Helyx.Compaction do
  @moduledoc """
  Shrinks the context before a provider call.

  A compaction plugin implements this behaviour. The session calls
  `compact/2` on the built context before every provider call. `opts` carries
  `:core`, `:session_id`, `:turn_id`, and `:cwd`.
  """

  use Helyx.Interface, mode: :single

  @callback compact(context :: Helyx.Context.t(), opts :: keyword()) :: Helyx.Context.t()

  @doc "Runs the registered plugin on the context. No plugin returns it unchanged."
  @spec compact(Helyx.Core.name(), Helyx.Context.t(), keyword()) :: Helyx.Context.t()
  def compact(core, context, opts) do
    case Helyx.Core.plugins(core, __MODULE__) do
      [plugin] -> plugin.compact(context, opts)
      [] -> context
    end
  end
end
