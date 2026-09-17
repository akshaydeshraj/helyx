defmodule Helyx.Context do
  @moduledoc """
  What a provider sees on one call: a system prompt and the messages.
  """

  defstruct system: nil, messages: []

  @type t :: %__MODULE__{system: String.t() | nil, messages: [Helyx.Message.t()]}
end
