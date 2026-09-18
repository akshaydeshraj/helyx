defmodule Helyx.MessageTest do
  use ExUnit.Case, async: true

  alias Helyx.Message

  test "tool output that is not valid UTF-8 is scrubbed at construction" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}

    message = Message.tool_result(call, {:ok, <<"hi", 255>>})
    assert Message.text(message) == "hi�"

    error = Message.tool_result(call, {:error, <<255>>})
    assert Message.text(error) == "�"
    assert error.is_error
  end

  test "valid_utf8? walks nested values and never raises" do
    assert Message.valid_utf8?(%{"a" => ["b", %{"c" => "d"}]})
    refute Message.valid_utf8?(%{"a" => [<<255>>]})
    refute Message.valid_utf8?(%{<<255>> => "v"})
    assert Message.valid_utf8?(~U[2026-09-18 00:00:00Z])
    assert Message.valid_utf8?([1 | 2])
    refute Message.valid_utf8?([<<255>> | 2])
  end

  test "valid tool output passes through unchanged" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    text = "héllo\n"

    assert Message.text(Message.tool_result(call, {:ok, text})) == text
  end
end
