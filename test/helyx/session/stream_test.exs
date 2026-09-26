defmodule Helyx.Session.StreamTest do
  use ExUnit.Case, async: true

  alias Helyx.{Context, Message}
  alias Helyx.Session.Stream, as: SessionStream

  @marker "integer of more than 100 digits removed"

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Test.Provider]})
    %{core: core}
  end

  defp run(core, model, opts \\ []) do
    SessionStream.run(%{
      model_context: nil,
      compaction: nil,
      provider: Keyword.get(opts, :provider, Helyx.Test.Provider),
      model: model,
      context: %Context{messages: Keyword.get(opts, :messages, [])},
      opts: [core: core, turn_id: "t1"],
      session: self(),
      turn_id: "t1",
      harness?: Keyword.get(opts, :harness?, false)
    })
  end

  # The messages the run sent to the session, in order.
  defp sent(acc \\ []) do
    receive do
      {tag, "t1", _} = message when tag in [:stream_event, :rejected_call] ->
        sent([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a valid stream forwards each event in order and returns done", %{core: core} do
    assert {:done, %{stop_reason: :end_turn, usage: %{}}} = run(core, "blocks")

    assert [
             {:stream_event, "t1", {:thinking_delta, "hm"}},
             {:stream_event, "t1", {:thinking_delta, "m"}},
             {:stream_event, "t1", {:text_delta, "Listing"}},
             {:stream_event, "t1", {:text_delta, "."}},
             {:stream_event, "t1", {:tool_call, %Message.ToolCall{id: "call_1"}}}
           ] = sent()
  end

  test "a malformed event is the terminal and stops the stream", %{core: core} do
    assert {:error, {:bad_stream_event, {:text_delta, 42}}} = run(core, "garbage")
    assert sent() == []
  end

  test "a delta that is not valid UTF-8 is a malformed event", %{core: core} do
    assert {:error, {:bad_stream_event, {:text_delta, <<"hi", 255>>}}} = run(core, "raw_bytes")
    assert sent() == []
  end

  test "an integer over the digit limit in arguments is capped and the call rejected first",
       %{core: core} do
    assert {:done, _} = run(core, "big_int")
    messages = sent()

    assert [
             {:rejected_call, "t1", %Message.ToolCall{id: "c1"} = rejected},
             {:stream_event, "t1", {:tool_call, first}} | _
           ] =
             messages

    assert rejected == first
    assert %{"n" => [%{"deep" => @marker}]} = first.arguments

    # The call at the limit passes and is not rejected.
    assert Enum.any?(messages, &match?({:stream_event, _, {:tool_call, %{id: "c3"}}}, &1))
    refute Enum.any?(messages, &match?({:rejected_call, _, %{id: "c3"}}, &1))
  end

  test "an integer over the digit limit in usage is capped, and the extra key dropped",
       %{core: core} do
    call = %Message.ToolCall{id: "c1", name: "upcase", arguments: %{}}
    messages = [Message.tool_result(call, {:ok, "ONE"})]

    assert {:done, done} = run(core, "big_int", messages: messages)
    assert done == %{stop_reason: :end_turn, usage: %{input: @marker, output: 3}}
  end

  test "a harness event from a model provider is a malformed event", %{core: core} do
    assert {:error, {:bad_stream_event, {:message_end, :end_turn, %{}}}} =
             run(core, "harness_event")

    assert [{:stream_event, "t1", {:text_delta, "hi"}}] = sent()
  end

  test "a harness provider can send harness events", %{core: core} do
    assert {:done, _} = run(core, "id1", provider: Helyx.Test.Harness, harness?: true)

    assert [
             {:stream_event, "t1", {:harness_session, "a", 0}},
             {:stream_event, "t1", {:text_delta, "ok"}}
           ] = sent()
  end

  test "the error reason of the provider call is capped", %{core: core} do
    assert {:error, {:oops, @marker}} = run(core, "refuse_int")
  end
end
