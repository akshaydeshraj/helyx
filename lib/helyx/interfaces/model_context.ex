defmodule Helyx.ModelContext do
  @moduledoc """
  Builds the context a provider sees on one call.

  A model context plugin implements this behaviour. The session builds a base
  `Helyx.Context` with the transcript and the tools, and `build/2` returns
  the context to send, usually with a system prompt added. `opts` carries
  `:core`, `:session_id`, `:turn_id`, and `:cwd`.
  """

  use Helyx.Interface, mode: :single

  @callback build(context :: Helyx.Context.t(), opts :: keyword()) :: Helyx.Context.t()
end
