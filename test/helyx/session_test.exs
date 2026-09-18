defmodule Helyx.SessionTest do
  # Session seam with a test provider whose streams end badly. The happy path
  # lives in the Fake provider plugin's tests.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Session}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Helyx.Test.Provider,
      Helyx.Test.Tool.Upcase,
      Helyx.Test.Tool.Kill,
      Helyx.Test.Tool.Slow,
      Helyx.Test.Tool.Binary
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp final_text(events) do
    Helyx.Message.text(Enum.find(events, &(&1.type == :turn_end)).data.message)
  end

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      1_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp stop_reason(events), do: List.last(events).data.stop_reason

  # Stops the session and waits until Registry frees its name, so a resume
  # that follows cannot race the asynchronous cleanup.
  defp stop_session(core, session, stop) do
    registry = Helyx.Core.sessions_registry(core)
    [{pid, _}] = Registry.lookup(registry, session.id)
    stop.(pid)
    await_free(registry, session.id, 100)
  end

  defp await_free(_registry, _id, 0), do: flunk("registry entry never freed")

  defp await_free(registry, id, tries) do
    if Registry.lookup(registry, id) != [] do
      Process.sleep(10)
      await_free(registry, id, tries - 1)
    end
  end

  test "a stream that ends without a terminal event ends the turn with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/empty")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == :stream_ended

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  @tag :capture_log
  test "a task crash fails the turn and the session accepts the next prompt", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert {:task_exit, {%RuntimeError{message: "boom"}, _}} = List.last(events).data.error

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  # Halt-on-error only cancels the provider's request if the session never
  # pulls past the error; the fixture's tail raises on a drain.
  test "an error event fails the turn without pulling the stream further", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/error_tail")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == :overloaded

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  test "consumption stops at the first terminal event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/overrun")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert final_text(events) == "kept"
    refute_receive {:helyx_event, _}, 100
  end

  @tag :capture_log
  test "a failure after deltas closes the partial message with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    types = Enum.map(events, & &1.type)

    assert Enum.slice(types, -4..-1) == [
             :message_start,
             :message_update,
             :message_end,
             :agent_end
           ]

    message_end = Enum.at(events, -2)
    assert %Helyx.Message{role: :assistant, stop_reason: :error} = message_end.data.message
    assert Helyx.Message.text(message_end.data.message) == "so far"
    assert {:task_exit, _} = message_end.data.error
    refute Enum.any?(events, &(&1.type == :turn_end))
  end

  test "two providers with the same id are rejected at session start" do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Test.Provider, Helyx.Test.ProviderTwin]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    assert {:error, {:ambiguous_provider, "test"}} = Session.start(core, model: "test/ok")
  end

  test "thinking, text, and tool call events build one assistant message in order", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/blocks")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    message =
      Enum.find_value(events, fn
        %{type: :message_end, data: %{message: %{role: :assistant} = m}} -> m
        _ -> nil
      end)

    assert message.content == [
             %Helyx.Message.Thinking{thinking: "hmm"},
             %Helyx.Message.Text{text: "Listing."},
             %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}
           ]

    assert Helyx.Message.text(message) == "Listing."
    updates = for %{type: :message_update, data: data} <- events, do: data

    assert Enum.take(updates, 5) == [
             %{thinking_delta: "hm"},
             %{thinking_delta: "m"},
             %{text_delta: "Listing"},
             %{text_delta: "."},
             %{tool_call: List.last(message.content)}
           ]
  end

  test "a malformed stream event fails the turn and the session lives", %{core: core} do
    for {model, event} <- [garbage: {:text_delta, 42}, wide: {:text_delta, "hello", :extra}] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      :ok = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      events = collect_until(:agent_end)
      assert List.last(events).data.error == {:bad_stream_event, event}

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:agent_end)) == :error
    end
  end

  test "a prompt during a turn is rejected", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert {:error, :turn_running} = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  test "the provider context goes through model context, then compaction" do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Test.Provider, Helyx.Test.ModelContext, Helyx.Test.Compaction]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    {:ok, session} = Session.start(core, model: "test/system")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "built for #{File.cwd!()}, compacted"
  end

  test "without model context and compaction plugins the context is unchanged", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/system")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "no system"
  end

  test "the hands report the registered tools and the provider sees them", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/tools")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "binary,kill,slow,upcase"
  end

  test "tool calls run on the hands and the loop continues until the provider stops", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/loop")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "HI|unknown tool: nope"

    types = Enum.map(events, & &1.type)
    assert Enum.count(types, &(&1 == :turn_start)) == 1
    assert Enum.count(types, &(&1 == :turn_end)) == 1
    assert Enum.count(types, &(&1 == :tool_execution_start)) == 2
    assert Enum.count(types, &(&1 == :tool_execution_end)) == 2
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

    ends = for %{type: :tool_execution_end, data: data} <- events, do: data.message
    by_id = Map.new(ends, &{&1.tool_call_id, &1})
    assert %Helyx.Message{role: :tool_result, tool_name: "upcase", is_error: false} = by_id["c1"]
    assert %Helyx.Message{role: :tool_result, tool_name: "nope", is_error: true} = by_id["c2"]
    assert Helyx.Message.text(by_id["c1"]) == "HI"
  end

  test "tool calls run one at a time, in call order", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/serial")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "1|2|3"

    order =
      for %{type: t, data: d} <- events, t in [:tool_execution_start, :tool_execution_end] do
        case d do
          %{tool_call: call} -> {t, call.id}
          %{message: message} -> {t, message.tool_call_id}
        end
      end

    assert order == [
             {:tool_execution_start, "1"},
             {:tool_execution_end, "1"},
             {:tool_execution_start, "2"},
             {:tool_execution_end, "2"},
             {:tool_execution_start, "3"},
             {:tool_execution_end, "3"}
           ]
  end

  test "a tool call with a bad field shape is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/bad_call")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:tool_call, %Helyx.Message.ToolCall{name: %{}}}} =
             List.last(events).data.error
  end

  test "a stop reason outside the format's set is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/bad_stop")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:done, %{stop_reason: :refusal}}} =
             List.last(events).data.error
  end

  test "a tool call whose arguments the file cannot hold is a malformed stream event", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/bad_args")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:tool_call, _}} = List.last(events).data.error
  end

  @tag :tmp_dir
  test "a terminal the file cannot hold fails the turn and leaves persistence on", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/recover", sessions_dir: dir)
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

    assert {:bad_stream_event, {:done, %{usage: %{"in" => {1, 2}}}}} =
             List.last(events).data.error

    :ok = Session.prompt(session, "again")
    collect_until(:agent_end)

    {:ok, restored} = Helyx.SessionFile.resume(dir, File.cwd!())
    assert "recovered" in Enum.map(restored.messages, &Helyx.Message.text/1)
  end

  test "a tool result with invalid bytes is made valid before it reaches the session", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/binary")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "a�b"

    result = Enum.find(events, &(&1.type == :tool_execution_end)).data.message
    assert Helyx.Message.text(result) == "a�b"
    refute result.is_error

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  test "a tool Task that dies gives an error result and the loop continues", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/kill")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert final_text(events) == "tool crashed: :killed"
  end

  test "two tools with one name are rejected at session start" do
    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Test.Provider, Helyx.Test.Tool.Upcase, Helyx.Test.Tool.UpcaseTwin]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    assert {:error, {:duplicate_tool_name, "upcase"}} = Session.start(core, model: "test/ok")
  end

  test "abort during tool calls ends the turn and answers every open call", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start} = started}, 1_000

    :ok = Session.abort(session)
    events = collect_until(:agent_end)
    assert stop_reason(events) == :aborted
    refute Enum.any?(events, &(&1.type == :turn_end))

    results = for %{type: :tool_execution_end, data: %{message: m}} <- events, do: m
    assert length(results) == 3
    assert Enum.all?(results, & &1.is_error)
    assert Enum.all?(results, &(Helyx.Message.text(&1) == "aborted"))

    # A late result for the aborted turn is dropped.
    [{pid, _}] = Registry.lookup(Helyx.Core.sessions_registry(core), session.id)
    send(pid, {:tool_result, started.turn_id, "1", {:ok, "late"}})

    :ok = Session.prompt(session, "again")
    events = collect_until(:agent_end)
    assert final_text(events) == "aborted|aborted|aborted"
    refute Enum.any?(events, &(inspect(&1.data) =~ "late"))
  end

  test "abort during the provider stream closes the partial message", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :message_update}}, 1_000

    :ok = Session.abort(session)
    events = collect_until(:agent_end)
    assert stop_reason(events) == :aborted

    message_end =
      Enum.find(events, fn event ->
        event.type == :message_end and match?(%{role: :assistant}, event.data.message)
      end)

    assert Helyx.Message.text(message_end.data.message) == "so far"
    assert message_end.data.error == :aborted
  end

  test "abort with no running turn is ok", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Session.subscribe(session)

    assert :ok = Session.abort(session)
    refute_receive {:helyx_event, _}, 50
  end

  # A crash of a linked process that is not a provider Task, the sessions
  # Registry for example, must take the session with it: a session that
  # outlives its registration keeps working where no client can reach it.
  @tag :capture_log
  test "an exit that is not from a provider Task stops the session", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    pid = Session.pid(session)
    ref = Process.monitor(pid)

    Process.exit(pid, {:shutdown, :registry_gone})
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :registry_gone}}, 1_000
  end

  # The ownership chain (ADR 0004): work inside the VM is linked to its
  # owner, so a killed session takes the provider Task, the hands, and the
  # tool Tasks with it, even through an untrappable kill.
  @tag :capture_log
  test "killing the session kills the provider Task", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/hang")
    :ok = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :message_update}}, 1_000

    [task] = Task.Supervisor.children(Helyx.Core.task_supervisor(core))
    ref = Process.monitor(task)
    Process.exit(Session.pid(session), :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
  end

  @tag :capture_log
  test "killing the session kills the hands and the tool Task", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    :ok = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}, 1_000

    pid = Session.pid(session)
    hands = :sys.get_state(pid).hands

    [task] =
      for task <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)),
          {:dictionary, dict} = Process.info(task, :dictionary),
          Keyword.has_key?(dict, :helyx_hands) do
        task
      end

    hands_ref = Process.monitor(hands)
    task_ref = Process.monitor(task)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^hands_ref, :process, _, _}, 1_000
    assert_receive {:DOWN, ^task_ref, :process, _, _}, 1_000
  end

  defp user_texts(events) do
    for %{type: :message_end, data: %{message: %Helyx.Message{role: :user} = m}} <- events,
        do: Helyx.Message.text(m)
  end

  defp queue_counts(events) do
    for %{type: :queue_update, data: data} <- events, do: data
  end

  test "steers during a tool run reach the next provider call after the result, in order", %{
    core: core
  } do
    {:ok, session} = Session.start(core, model: "test/steer")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}, 1_000
    :ok = Session.steer(session, "s1")
    :ok = Session.steer(session, "s2")

    events = collect_until(:agent_end)
    assert final_text(events) == "hello|s1|s2"

    result_at = Enum.find_index(events, &(&1.type == :tool_execution_end))

    steer_at =
      Enum.find_index(events, fn
        %Event{type: :message_end, data: %{message: %Helyx.Message{role: :user} = m}} ->
          Helyx.Message.text(m) == "s1"

        _ ->
          false
      end)

    assert result_at < steer_at

    assert queue_counts(events) == [
             %{steers: 1, follow_ups: 0},
             %{steers: 2, follow_ups: 0},
             %{steers: 0, follow_ups: 0}
           ]
  end

  test "a follow-up during a turn starts a new turn after agent_end", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    :ok = Session.follow_up(session, "next")

    first = collect_until(:agent_end)
    assert user_texts(first) == ["hello"]
    assert queue_counts(first) == [%{steers: 0, follow_ups: 1}]

    second = collect_until(:agent_end)
    assert [:queue_update, :agent_start | _] = Enum.map(second, & &1.type)
    assert List.first(second).turn_id == nil
    assert user_texts(second) == ["next"]
    assert queue_counts(second) == [%{steers: 0, follow_ups: 0}]
  end

  test "a steer left at turn end starts a new turn", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    :ok = Session.steer(session, "later")

    collect_until(:agent_end)
    second = collect_until(:agent_end)
    assert user_texts(second) == ["later"]
  end

  test "a steer or follow-up with no turn running starts a turn at once", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Session.subscribe(session)

    :ok = Session.follow_up(session, "go")
    events = collect_until(:agent_end)
    assert user_texts(events) == ["go"]
    assert stop_reason(events) == :end_turn

    :ok = Session.steer(session, "again")
    events = collect_until(:agent_end)
    assert user_texts(events) == ["again"]
  end

  test "abort drops queued steers and follow-ups", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}, 1_000
    :ok = Session.steer(session, "s")
    :ok = Session.follow_up(session, "f")
    assert Session.queue_count(session) == %{steers: 1, follow_ups: 1}

    :ok = Session.abort(session)
    assert Session.queue_count(session) == %{steers: 0, follow_ups: 0}
    events = collect_until(:agent_end)
    assert stop_reason(events) == :aborted
    assert List.last(queue_counts(events)) == %{steers: 0, follow_ups: 0}

    refute_receive {:helyx_event, %Event{type: :agent_start}}, 100
  end

  test "a full queue rejects the next steer or follow-up", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}, 1_000

    # One under the limit, then at the limit, with multibyte text.
    for n <- 1..31, do: :ok = Session.steer(session, "stér #{n}")
    assert Session.queue_count(session) == %{steers: 31, follow_ups: 0}
    :ok = Session.steer(session, "stér 32 🚀")
    for n <- 1..32, do: :ok = Session.follow_up(session, "折り返し #{n}")

    # 64 accepted writes, one queue_update each.
    for _ <- 1..64, do: assert_receive({:helyx_event, %Event{type: :queue_update}}, 1_000)

    # One over the limit is rejected, changes nothing, and emits no event.
    assert Session.steer(session, "s33") == {:error, :queue_full}
    assert Session.follow_up(session, "f33") == {:error, :queue_full}
    assert Session.queue_count(session) == %{steers: 32, follow_ups: 32}
    refute_receive {:helyx_event, %Event{type: :queue_update}}, 50

    :ok = Session.abort(session)
  end

  @tag :tmp_dir
  test "a session with a sessions dir writes a header and completed messages", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/blocks", sessions_dir: dir)
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    collect_until(:agent_end)

    [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
    entries = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [
             %{"type" => "session", "version" => 1, "model" => "test/blocks"},
             %{"type" => "message", "role" => "user"},
             %{"type" => "message", "role" => "assistant", "stop_reason" => "end_turn"},
             %{"type" => "message", "role" => "tool_result", "tool_call_id" => "call_1"},
             %{"type" => "message", "role" => "assistant"}
           ] = entries

    assert Enum.at(entries, 0)["cwd"] == File.cwd!()

    assert [%{"type" => "thinking"}, %{"type" => "text"}, %{"type" => "tool_call"}] =
             Enum.at(entries, 2)["content"]

    ids = Enum.map(entries, & &1["id"])
    assert Enum.map(entries, & &1["parent_id"]) == [nil | Enum.drop(ids, -1)]
  end

  @tag :tmp_dir
  test "resume restores the transcript and the next provider call sees it", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/transcript", sessions_dir: dir)
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert final_text(collect_until(:agent_end)) == "user:hello"

    stop_session(core, session, &GenServer.stop/1)

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    assert resumed.id == session.id
    :ok = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")

    assert final_text(collect_until(:agent_end)) ==
             "user:hello\nassistant:user:hello\nuser:again"
  end

  @tag :tmp_dir
  test "resume keeps a reused tool call id open until its own result", %{
    core: core,
    tmp_dir: dir
  } do
    call = %Helyx.Message.ToolCall{id: "c1", name: "slow", arguments: %{}}
    {:ok, file} = Helyx.SessionFile.create(dir, "reuse", File.cwd!(), "test/transcript")

    [
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]},
      Helyx.Message.tool_result(call, {:ok, "first answer"}),
      %Helyx.Message{role: :assistant, stop_reason: :tool_use, content: [call]}
    ]
    |> Enum.reduce(file, &Helyx.SessionFile.append_message(&2, &1))

    {:ok, _session} = Session.resume(core, sessions_dir: dir)

    {:ok, restored} = Helyx.SessionFile.resume(dir, File.cwd!())
    assert [_call1, _result1, _call2, aborted] = restored.messages
    assert %Helyx.Message{role: :tool_result, tool_call_id: "c1", is_error: true} = aborted
    assert Helyx.Message.text(aborted) == "aborted"
  end

  @tag :tmp_dir
  @tag :capture_log
  test "resume after a crash mid-turn answers every open tool call", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/abort", sessions_dir: dir)
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}, 1_000

    stop_session(core, session, &Process.exit(&1, :kill))

    {:ok, resumed} = Session.resume(core, sessions_dir: dir)
    :ok = Session.subscribe(resumed)

    :ok = Session.prompt(resumed, "again")
    assert final_text(collect_until(:agent_end)) == "aborted|aborted|aborted"
  end

  test "a delta that is not valid UTF-8 is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/raw_bytes")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert {:bad_stream_event, {:text_delta, <<"hi", 255>>}} = List.last(events).data.error
  end

  test "a tool call that is not valid UTF-8 is a malformed stream event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/raw_call")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert {:bad_stream_event, {:tool_call, _}} = List.last(events).data.error
  end

  test "a prompt that is not valid UTF-8 is rejected and the session lives", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Session.subscribe(session)

    assert {:error, :invalid_utf8} = Session.prompt(session, <<255, 254>>)

    :ok = Session.prompt(session, "hello")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a write failure turns persistence off and the session lives", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    :ok = Session.subscribe(session)

    File.rm_rf!(dir)

    :ok = Session.prompt(session, "hello")
    assert stop_reason(collect_until(:agent_end)) == :end_turn

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  @tag :tmp_dir
  test "a working directory that is gone gives an error result", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/loop", cwd: Path.join(dir, "gone"))
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) =~ "working directory does not exist"
  end
end
