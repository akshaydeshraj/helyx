defmodule Helyx.Compaction.None do
  @moduledoc """
  A compaction plugin that does nothing. It keeps the compaction seam real
  until a real strategy exists.
  """

  @behaviour Helyx.Compaction

  @impl true
  def compact(context, _opts), do: context
end
