defmodule Helyx.Message do
  @moduledoc """
  One message in a conversation: from the user, from the assistant, or a tool
  result. Content is a list of blocks. The shape is provider neutral.
  """

  defmodule Text do
    @moduledoc "A text content block."
    @enforce_keys [:text]
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :model, :stop_reason, usage: %{}]

  @type block :: Text.t()
  @type role :: :user | :assistant | :tool_result
  @type t :: %__MODULE__{
          role: role(),
          content: [block()],
          model: String.t() | nil,
          stop_reason: atom() | nil,
          usage: map()
        }

  @doc "Builds a user message with one text block."
  @spec user(String.t()) :: t()
  def user(text) when is_binary(text), do: %__MODULE__{role: :user, content: [%Text{text: text}]}

  @doc "Concatenates the text blocks of a message."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&match?(%Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end
end
