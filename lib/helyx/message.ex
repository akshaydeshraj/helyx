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

  @doc "Builds the tool result message for a call from `{:ok, text}` or `{:error, text}`."
  @spec tool_result(ToolCall.t(), {:ok, String.t()} | {:error, String.t()}) :: t()
  def tool_result(%ToolCall{} = call, {:ok, text}), do: tool_result(call, text, false)
  def tool_result(%ToolCall{} = call, {:error, text}), do: tool_result(call, text, true)

  defp tool_result(%ToolCall{id: id, name: name}, text, is_error) when is_binary(text) do
    %__MODULE__{
      role: :tool_result,
      tool_call_id: id,
      tool_name: name,
      is_error: is_error,
      content: [%Text{text: scrub(text)}]
    }
  end

  # Tool output is the one text source that can carry bytes that are not
  # UTF-8: prompts are rejected in `Helyx.Session.prompt/2` and provider
  # deltas fail the turn as malformed stream events. Scrubbing here keeps
  # every consumer safe: the session file, and any provider that
  # JSON-encodes the transcript. The valid path copies nothing.
  defp scrub(text) do
    if String.valid?(text, :fast_ascii), do: text, else: String.replace_invalid(text)
  end

  @doc """
  Whether every string in the value, keys and values at any depth, is
  valid UTF-8.

  The cheap transcript-ingress check, for the values that are plain text:
  prompts and provider deltas are rejected against it, tool output is
  scrubbed instead. A compound provider value that must round-trip to the
  file is checked against `encodable?/1`, the stricter predicate.
  """
  @spec valid_utf8?(term()) :: boolean()
  def valid_utf8?(value) when is_binary(value), do: String.valid?(value)
  def valid_utf8?(%_{} = value), do: valid_utf8?(Map.from_struct(value))

  def valid_utf8?(value) when is_map(value),
    do: Enum.all?(value, fn {key, val} -> valid_utf8?(key) and valid_utf8?(val) end)

  # The head-tail walk never raises on an improper list; the catch-all
  # covers the empty list and every non-text terminal.
  def valid_utf8?([head | tail]), do: valid_utf8?(head) and valid_utf8?(tail)
  def valid_utf8?(_value), do: true

  @doc """
  Whether the value round-trips to the session file, which holds only JSON.

  Stricter than `valid_utf8?/1`: it also rejects a term JSON cannot encode,
  such as a tuple, a pid, or a non-string, non-atom map key. Used at the
  provider-stream boundary for a tool call's fields and a turn's usage,
  where the value is arbitrary and must survive the write to disk.
  """
  @spec encodable?(term()) :: boolean()
  def encodable?(value) do
    JSON.encode!(value)
    true
  rescue
    _ -> false
  end

  @doc "Concatenates the text blocks of a message. Other blocks are skipped."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    for %Text{text: text} <- content, into: "", do: text
  end
end
