defmodule Helyx.Message do
  @moduledoc """
  One message in a conversation: from the user, from the assistant, or a tool
  result. Content is a list of blocks. The shape is provider neutral and
  follows ADR 0001; the field names are the ones `docs/features/coding-agent.md`
  lists under the session file.

  A tool result message links to its call with `tool_call_id` and `tool_name`,
  and flags a failed call with `is_error`.
  """

  defmodule Text do
    @moduledoc "A text content block."
    @enforce_keys [:text]
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule Thinking do
    @moduledoc "A thinking block. `signature` is set when the provider sends one."
    @enforce_keys [:thinking]
    defstruct [:thinking, :signature]
    @type t :: %__MODULE__{thinking: String.t(), signature: String.t() | nil}
  end

  defmodule ToolCall do
    @moduledoc "A tool call block. `arguments` is the decoded argument map."
    @enforce_keys [:id, :name, :arguments]
    defstruct [:id, :name, :arguments]
    @type t :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}
  end

  defmodule Image do
    @moduledoc "An image block with base64 `data`."
    @enforce_keys [:mime_type, :data]
    defstruct [:mime_type, :data]
    @type t :: %__MODULE__{mime_type: String.t(), data: String.t()}
  end

  @enforce_keys [:role, :content]
  defstruct [
    :role,
    :content,
    :model,
    :stop_reason,
    :tool_call_id,
    :tool_name,
    is_error: false,
    usage: %{}
  ]

  @type block :: Text.t() | Thinking.t() | ToolCall.t() | Image.t()
  @type role :: :user | :assistant | :tool_result
  @type t :: %__MODULE__{
          role: role(),
          content: [block()],
          model: String.t() | nil,
          stop_reason: atom() | nil,
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          is_error: boolean(),
          usage: map()
        }

  @doc "Builds a user message with one text block."
  @spec user(String.t()) :: t()
  def user(text) when is_binary(text), do: %__MODULE__{role: :user, content: [%Text{text: text}]}

  @doc "Concatenates the text blocks of a message. Other blocks are skipped."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    for %Text{text: text} <- content, into: "", do: text
  end
end
