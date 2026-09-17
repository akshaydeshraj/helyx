defmodule Helyx.Context do
  @moduledoc """
  What a provider sees on one call: a system prompt, the messages, and the
  tools the hands can run.
  """

  defstruct system: nil, messages: [], tools: []

  @type t :: %__MODULE__{
          system: String.t() | nil,
          messages: [Helyx.Message.t()],
          tools: [Helyx.Tool.spec()]
        }
end
