defmodule Helyx.TUI.ViewModelTest do
  # The event fold, driven by scripted event lists, as the ticket requires.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message}
  alias Helyx.TUI.ViewModel

  # Builds a session's event list with sequence numbers assigned in order.
  defp events(specs) do
    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {{type, data}, seq} ->
      %Event{type: type, session_id: "s", turn_id: "t", seq: seq, data: data}
    end)
  end

  defp fold(specs),
    do: Enum.reduce(events(specs), ViewModel.new("test/model"), &ViewModel.apply(&2, &1))

  defp tool_end(result), do: {:tool_execution_end, %{message: result}}

  defp user(text), do: Message.user(text)

  defp assistant(blocks, stop_reason \\ :end_turn) do
    %Message{role: :assistant, content: blocks, model: "test/model", stop_reason: stop_reason}
  end

  test "a new view model shows the model and an idle session" do
    vm = ViewModel.new("test/model")
    assert vm.model == "test/model"
    assert vm.cells == []
    assert vm.streaming == nil
    refute vm.running?
    assert vm.queue == %{steers: 0, follow_ups: 0}
  end

  test "a prompt and a streamed answer become cells in order" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
    answer = assistant([%Message.Text{text: "Listing."}, call], :tool_use)

    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_start, %{message: user("hello")}},
        {:message_end, %{message: user("hello")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{text_delta: "List"}},
        {:message_update, %{text_delta: "ing."}},
        {:message_update, %{tool_call: call}},
        {:message_end, %{message: answer}}
      ])

    assert [%Message{role: :user}, %Message{role: :assistant} = done] = vm.cells
    assert Message.text(done) == "Listing."
    assert vm.streaming == nil
    assert vm.running?
  end

  test "deltas stream into the open assistant message" do
    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{thinking_delta: "hm"}},
        {:message_update, %{thinking_delta: "m"}},
        {:message_update, %{text_delta: "Hi"}},
        {:message_update, %{text_delta: "!"}}
      ])

    assert vm.streaming == [
             %Message.Text{text: "Hi!"},
             %Message.Thinking{thinking: "hmm"}
           ]
  end

  test "tool calls and results attach as they happen" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
    result = Message.tool_result(call, {:ok, "lib\ntest"})

    started =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:message_end, %{message: assistant([call], :tool_use)}},
        {:tool_execution_start, %{tool_call: call}}
      ])

    assert List.last(started.cells) == {:tool, call, nil}

    finished =
      ViewModel.apply(started, %Event{
        type: :tool_execution_end,
        session_id: "s",
        turn_id: "t",
        seq: 6,
        data: %{message: result}
      })

    assert List.last(finished.cells) == {:tool, call, result}
  end

  # A rejected `/model` command adds a notice while the tool runs (#83).
  for {name, outcome} <- [{"an ok", {:ok, "lib"}}, {"an error", {:error, "exit 1"}}] do
    test "#{name} result attaches past a notice added during the tool run" do
      call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
      result = Message.tool_result(call, unquote(outcome))

      vm =
        [{:tool_execution_start, %{tool_call: call}}]
        |> fold()
        |> ViewModel.notice("usage: /model provider/model")
        |> ViewModel.apply(hd(events([tool_end(result)])))

      assert vm.cells == [{:tool, call, result}, {:notice, "usage: /model provider/model"}]
    end
  end

  # The session runs tool calls one at a time (start, end, start, end). The
  # fold does not depend on that order: each open cell gets its own result.
  test "two open tool cells get their own results, in any order" do
    c1 = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    c2 = %Message.ToolCall{id: "c2", name: "read", arguments: %{}}
    r1 = Message.tool_result(c1, {:ok, "one"})
    r2 = Message.tool_result(c2, {:error, "two"})

    starts = [
      {:tool_execution_start, %{tool_call: c1}},
      {:tool_execution_start, %{tool_call: c2}}
    ]

    assert fold(starts ++ [tool_end(r1), tool_end(r2)]).cells == [
             {:tool, c1, r1},
             {:tool, c2, r2}
           ]

    assert fold(starts ++ [tool_end(r2), tool_end(r1)]).cells == [
             {:tool, c1, r1},
             {:tool, c2, r2}
           ]
  end

  test "the session order, one call at a time, attaches each result" do
    c1 = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    c2 = %Message.ToolCall{id: "c2", name: "read", arguments: %{}}
    r1 = Message.tool_result(c1, {:ok, "one"})
    r2 = Message.tool_result(c2, {:ok, "two"})

    vm =
      fold([
        {:tool_execution_start, %{tool_call: c1}},
        tool_end(r1),
        {:tool_execution_start, %{tool_call: c2}},
        tool_end(r2)
      ])

    assert vm.cells == [{:tool, c1, r1}, {:tool, c2, r2}]
  end

  test "a result goes to the newest open cell and never replaces a result" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    first = Message.tool_result(call, {:ok, "first"})
    second = Message.tool_result(call, {:ok, "second"})
    start = {:tool_execution_start, %{tool_call: call}}

    # A provider can use the same id again in a later turn.
    assert fold([start, tool_end(first), start, tool_end(second)]).cells ==
             [{:tool, call, first}, {:tool, call, second}]

    # A second result for a closed cell changes nothing.
    assert fold([start, tool_end(first), tool_end(second)]).cells == [{:tool, call, first}]

    # An old cell that stayed open does not take the result of a new call.
    assert fold([start, start, tool_end(second)]).cells ==
             [{:tool, call, nil}, {:tool, call, second}]
  end

  test "only a tool result message with a binary call id attaches" do
    no_id = %Message.ToolCall{id: nil, name: "bash", arguments: %{}}
    specs = [{:tool_execution_start, %{tool_call: no_id}}]
    assert fold(specs ++ [tool_end(user("hi"))]).cells == [{:tool, no_id, nil}]

    assert fold(specs ++ [tool_end(Message.tool_result(no_id, {:ok, "x"}))]).cells == [
             {:tool, no_id, nil}
           ]

    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    specs = [{:tool_execution_start, %{tool_call: call}}]

    assert fold(specs ++ [tool_end(%{user("hi") | tool_call_id: "c1"})]).cells == [
             {:tool, call, nil}
           ]
  end

  test "a result for an unknown call changes nothing" do
    call = %Message.ToolCall{id: "c9", name: "bash", arguments: %{}}
    result = Message.tool_result(call, {:error, "aborted"})

    vm = fold([{:agent_start, %{}}, tool_end(result)])
    assert vm.cells == []

    # Also with cells, none of them an open tool cell for that id.
    other = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    specs = [{:message_end, %{message: user("hi")}}, {:tool_execution_start, %{tool_call: other}}]
    assert fold(specs ++ [tool_end(result)]).cells == fold(specs).cells
  end

  test "an aborted turn closes the stream and shows a notice" do
    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{text_delta: "so far"}},
        {:message_end,
         %{message: assistant([%Message.Text{text: "so far"}], :aborted), error: :aborted}},
        {:agent_end, %{stop_reason: :aborted}}
      ])

    refute vm.running?
    assert vm.streaming == nil
    assert [_user, %Message{stop_reason: :aborted}, {:notice, "aborted"}] = vm.cells
  end

  test "a failed turn shows the error" do
    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:agent_end, %{stop_reason: :error, error: :stream_ended}}
      ])

    refute vm.running?
    assert List.last(vm.cells) == {:notice, "error: :stream_ended"}
  end

  test "queue updates change the counts, including the nil-turn drain" do
    vm =
      fold([
        {:agent_start, %{}},
        {:queue_update, %{steers: 1, follow_ups: 0}},
        {:queue_update, %{steers: 1, follow_ups: 2}}
      ])

    assert vm.queue == %{steers: 1, follow_ups: 2}

    drain = %Event{
      type: :queue_update,
      session_id: "s",
      turn_id: nil,
      seq: 4,
      data: %{steers: 0, follow_ups: 0}
    }

    assert ViewModel.apply(vm, drain).queue == %{steers: 0, follow_ups: 0}
  end

  test "a malformed message_update changes nothing" do
    vm = fold([{:agent_start, %{}}, {:message_update, %{weird: 1, extra: 2}}])
    assert vm.streaming == nil

    malformed = [
      {:message_update, nil},
      {:message_update, %{text_delta: 123}},
      {:message_update, %{tool_call: :junk}},
      {:tool_execution_start, %{tool_call: "bash"}},
      {:queue_update, nil},
      {:queue_update, %{steers: %{}, follow_ups: 0}}
    ]

    for {type, data} <- malformed do
      event = %Event{type: type, session_id: "s", turn_id: "t", seq: 3, data: data}
      assert ViewModel.apply(vm, event) == vm
    end
  end

  test "agent_end with an open stream and no message_end still closes it" do
    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:agent_end, %{stop_reason: :error, error: :boom}}
      ])

    assert vm.streaming == nil
  end

  test "a model change updates the model; a malformed one changes nothing" do
    vm = fold(model_change: %{model: "other/model"})
    assert vm.model == "other/model"
    assert fold(model_change: %{model: 42}).model == "test/model"
    assert fold(model_change: %{}).model == "test/model"
  end

  test "a reject sets the reason, events keep it, and clear_reason/1 removes it" do
    vm = ViewModel.new("test/model")
    assert vm.reason == nil

    vm = ViewModel.reject(vm, "not sent: the queue is full")
    assert vm.reason == "not sent: the queue is full"
    assert vm.cells == []

    # A session event does not clear the reason; the TUI does, on a key press or a paste.
    [event] = events([{:queue_update, %{steers: 1, follow_ups: 0}}])
    kept = ViewModel.apply(vm, event)
    assert kept.reason == "not sent: the queue is full"

    assert ViewModel.clear_reason(kept).reason == nil
  end

  test "a client notice joins the cells" do
    vm = ViewModel.notice(ViewModel.new("test/model"), "unknown provider: x")
    assert vm.cells == [{:notice, "unknown provider: x"}]
  end
end
