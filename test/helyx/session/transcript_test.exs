defmodule Helyx.Session.TranscriptTest do
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Session.Transcript

  defp call(id), do: %Message.ToolCall{id: id, name: "read", arguments: %{}}

  defp assistant(content, model \\ "claude-code/sonnet"),
    do: %Message{role: :assistant, content: content, model: model}

  defp result(id), do: Message.tool_result(call(id), {:ok, "done"})

  describe "open_calls/1" do
    test "gives the calls with no result, in call order" do
      transcript = [
        Message.user("hi"),
        assistant([call("a"), call("b"), call("c")]),
        result("b")
      ]

      assert Transcript.open_calls(transcript) == [call("a"), call("c")]
    end

    test "a result answers the first open call with its id, and a stray result changes nothing" do
      transcript = [assistant([call("a")]), assistant([call("a")]), result("a"), result("x")]
      assert Transcript.open_calls(transcript) == [call("a")]
      assert Transcript.open_calls([]) == []
    end
  end

  describe "last_assistant/1" do
    test "gives the last assistant message, or nil" do
      last = assistant([], "fake/echo")

      assert Transcript.last_assistant([assistant([]), Message.user("x"), last, result("a")]) ==
               last

      assert Transcript.last_assistant([Message.user("x")]) == nil
    end
  end

  describe "resumable/3" do
    test "resumes when the provider answered last after its session started" do
      transcript = [Message.user("a"), assistant([])]

      assert Transcript.resumable(transcript, %{"claude-code" => {"h1", 1}}, "claude-code") ==
               "h1"
    end

    test "does not resume without a session, before the session answered, or after another provider" do
      transcript = [Message.user("a"), assistant([])]
      sessions = %{"claude-code" => {"h1", 2}}

      assert Transcript.resumable(transcript, %{}, "claude-code") == nil
      assert Transcript.resumable(transcript, sessions, "claude-code") == nil

      other = transcript ++ [assistant([], "fake/echo")]
      assert Transcript.resumable(other, %{"claude-code" => {"h1", 0}}, "claude-code") == nil
    end

    test "does not resume after an assistant message with no model" do
      transcript = [assistant([], nil)]
      assert Transcript.resumable(transcript, %{"claude-code" => {"h1", 0}}, "claude-code") == nil
    end
  end
end
