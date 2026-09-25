defmodule Helyx.Provider.CodexTest do
  # A fake `codex` on PATH speaks the JSON-RPC lines of `codex app-server`
  # in the shapes that `docs/research/codex-app-server.md` records. Run N
  # saves its arguments to `args.N` and each line it reads to `stdin.N`;
  # for a request or notification of method M it runs `on.N.M` (M with `/`
  # as `_`), which prints the canned answer. It exits at the end of its
  # input. PATH is global, so this module is not async.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  alias Helyx.{Event, HarnessIO, Message, Session, SessionFile}
  alias Helyx.Provider.{Codex, Fake}

  @tid "019a0000-0000-7000-8000-000000000001"
  @fresh "019a0000-0000-7000-8000-000000000002"

  @fake """
  #!/bin/sh
  d=$(dirname "$0")
  n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
  echo $n > "$d/count"
  for a in "$@"; do printf '%s\\n' "$a"; done > "$d/args.$n"
  while IFS= read -r line; do
    printf '%s\\n' "$line" >> "$d/stdin.$n"
    m=$(printf '%s\\n' "$line" | perl -MJSON::PP -ne 'print decode_json($_)->{method} // ""' | tr / _)
    if [ -n "$m" ] && [ -f "$d/on.$n.$m" ]; then . "$d/on.$n.$m"; fi
  done
  """

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "codex"), @fake)
    File.chmod!(Path.join(bin, "codex"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Codex, Fake]})
    work = Path.join(tmp, "work")
    File.mkdir_p!(work)
    %{core: core, bin: bin, work: work, sessions: Path.join(tmp, "sessions")}
  end

  # Protocol lines

  defp j(map), do: JSON.encode!(map)

  defp note(tid, method, params),
    do: j(%{method: method, params: Map.put(params, :threadId, tid), emittedAtMs: 1})

  defp thread(tid), do: %{id: tid, cwd: "/work", model: "gpt-6-luna", path: "/r.jsonl"}

  defp delta(tid, item, text),
    do: note(tid, "item/agentMessage/delta", %{turnId: "turn1", itemId: item, delta: text})

  defp started(tid, item), do: note(tid, "item/started", %{turnId: "turn1", item: item})
  defp completed(tid, item), do: note(tid, "item/completed", %{turnId: "turn1", item: item})

  defp message(tid, id, text) do
    item = %{type: "agentMessage", id: id, phase: "final_answer"}

    [
      started(tid, Map.put(item, :text, "")),
      delta(tid, id, text),
      completed(tid, Map.put(item, :text, text))
    ]
  end

  defp command(id, fields),
    do:
      Map.merge(
        %{type: "commandExecution", id: id, command: "/bin/zsh -lc ls", cwd: "/work"},
        fields
      )

  defp usage(tid) do
    note(tid, "thread/tokenUsage/updated", %{
      turnId: "turn1",
      tokenUsage: %{last: %{inputTokens: 12, outputTokens: 7}, total: %{inputTokens: 12}}
    })
  end

  defp turn_end(tid, status, error \\ nil) do
    note(tid, "turn/completed", %{
      turn: %{id: "turn1", items: [], status: status, error: error && %{message: error}}
    })
  end

  # A turn: the turn/start answer, then `lines`.
  defp turn(tid, lines) do
    [
      j(%{id: 5, result: %{turn: %{id: "turn1", status: "inProgress"}}}),
      note(tid, "turn/started", %{turn: %{id: "turn1", status: "inProgress"}}) | lines
    ]
  end

  # Writes the answer of run `n` to `method`: `lines`, then `tail` as shell
  # code.
  defp on(bin, n, method, lines, tail \\ "") do
    name = String.replace(method, "/", "_")
    File.write!(Path.join(bin, "out.#{n}.#{name}"), Enum.map(lines, &[&1, "\n"]))
    File.write!(Path.join(bin, "on.#{n}.#{name}"), ~s(cat "$d/out.#{n}.#{name}"\n) <> tail)
  end

  defp initialize(bin, n),
    do: on(bin, n, "initialize", [j(%{id: 1, result: %{userAgent: "fake", platformOs: "macos"}})])

  # A run that starts thread `tid`, takes the replay, and runs `lines` as
  # its turn.
  defp fresh(bin, n, tid, lines, tail \\ "") do
    initialize(bin, n)

    on(bin, n, "thread/start", [
      j(%{id: 3, result: %{thread: thread(tid)}}),
      j(%{method: "thread/started", params: %{thread: thread(tid)}})
    ])

    on(bin, n, "thread/inject_items", [j(%{id: 4, result: %{}})])
    on(bin, n, "turn/start", turn(tid, lines), tail)
  end

  defp resumed(bin, n, tid, lines) do
    initialize(bin, n)
    on(bin, n, "thread/resume", [j(%{id: 2, result: %{thread: thread(tid)}})])
    on(bin, n, "turn/start", turn(tid, lines))
  end

  defp reply(tid, text),
    do: message(tid, "msg_1", text) ++ [usage(tid), turn_end(tid, "completed")]

  defp stdin(bin, n) do
    bin
    |> Path.join("stdin.#{n}")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp request(bin, n, method), do: Enum.find(stdin(bin, n), &(&1["method"] == method))

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      5_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp start(ctx, model \\ "codex/gpt-6-luna") do
    {:ok, session} =
      Session.start(ctx.core, model: model, cwd: ctx.work, sessions_dir: ctx.sessions)

    :ok = Session.subscribe(session)
    session
  end

  defp prompt(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:agent_end)
  end

  # Runs the stream in a Task of its own, without a session: the stream
  # traps exits.
  defp run_direct(messages, work) do
    fn ->
      {:ok, stream} = Codex.stream("m", %Helyx.Context{messages: messages}, cwd: work)
      Enum.to_list(stream)
    end
    |> Task.async()
    |> Task.await(10_000)
  end

  defp messages(events), do: for(%Event{type: :message_end, data: %{message: m}} <- events, do: m)
  defp of_type(events, type), do: for(%Event{type: ^type, data: data} <- events, do: data)

  @moduletag :tmp_dir

  @done %{status: "completed", aggregatedOutput: "out", exitCode: 0}

  test "a turn: text, tool calls, and tool results join the transcript, and the id is stored",
       %{bin: bin} = ctx do
    fresh(
      bin,
      1,
      @tid,
      message(@tid, "msg_a", "I will list.") ++
        [
          started(@tid, command("exec-1", %{status: "inProgress"})),
          # A sub-agent's thread stays inside the harness.
          delta("019a0000-0000-7000-8000-00000000000f", "msg_x", "not mine"),
          completed(
            @tid,
            command("exec-1", %{status: "completed", aggregatedOutput: "a.txt\n", exitCode: 0})
          )
        ] ++ reply(@tid, "One file.")
    )

    session = start(ctx)
    events = prompt(session, "list the files")

    assert %{"params" => %{"clientInfo" => %{"name" => "helyx"}}} =
             request(bin, 1, "initialize")

    assert %{"method" => "initialized"} = Enum.at(stdin(bin, 1), 1)

    assert %{
             "params" => %{
               "approvalPolicy" => "never",
               "sandbox" => "danger-full-access",
               "model" => "gpt-6-luna",
               "cwd" => cwd
             }
           } = request(bin, 1, "thread/start")

    assert cwd == ctx.work
    assert request(bin, 1, "thread/inject_items") == nil

    assert %{"params" => %{"threadId" => @tid, "input" => [%{"text" => "list the files"}]}} =
             request(bin, 1, "turn/start")

    assert ["app-server"] = bin |> Path.join("args.1") |> File.read!() |> String.split()

    assert [%{provider: "codex", harness_session_id: @tid, lost: false, cut: 0}] =
             of_type(events, :harness_session)

    call = %Message.ToolCall{
      id: "exec-1",
      name: "commandExecution",
      arguments: %{"command" => "/bin/zsh -lc ls", "cwd" => "/work"}
    }

    assert [
             %Message{role: :user},
             %Message{role: :assistant, stop_reason: :tool_use, model: "codex/gpt-6-luna"} =
               first,
             %Message{role: :assistant, stop_reason: :end_turn} = last
           ] = messages(events)

    assert first.content == [%Message.Text{text: "I will list."}, call]
    assert last.content == [%Message.Text{text: "One file."}]
    assert last.usage == %{"inputTokens" => 12, "outputTokens" => 7}

    assert [%{message: %Message{role: :tool_result, tool_call_id: "exec-1"} = result}] =
             of_type(events, :tool_execution_end)

    assert Message.text(result) == "a.txt\n"
    refute result.is_error
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)

    assert {:ok, %{harness_sessions: %{"codex" => {@tid, 1}}}} =
             SessionFile.resume(ctx.sessions, ctx.work)
  end

  test "a later turn and a resumed session resume the thread and send only the prompt",
       %{bin: bin} = ctx do
    fresh(bin, 1, @tid, reply(@tid, "Hi."))
    resumed(bin, 2, @tid, reply(@tid, "Again."))
    resumed(bin, 3, @tid, reply(@tid, "Back."))

    session = start(ctx)
    prompt(session, "hello")
    events = prompt(session, "again")

    assert %{
             "params" => %{
               "threadId" => @tid,
               "excludeTurns" => true,
               "approvalPolicy" => "never",
               "sandbox" => "danger-full-access"
             }
           } = request(bin, 2, "thread/resume")

    assert request(bin, 2, "thread/start") == nil
    assert request(bin, 2, "thread/inject_items") == nil
    assert %{"params" => %{"input" => [%{"text" => "again"}]}} = request(bin, 2, "turn/start")
    assert of_type(events, :harness_session) == []

    GenServer.stop(Session.pid(session))
    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    :ok = Session.subscribe(session)
    prompt(session, "back")

    assert %{"params" => %{"threadId" => @tid}} = request(bin, 3, "thread/resume")
    assert %{"params" => %{"input" => [%{"text" => "back"}]}} = request(bin, 3, "turn/start")
  end

  test "a lost thread starts a fresh one on the same run, with the transcript replayed",
       %{bin: bin} = ctx do
    fresh(bin, 1, @tid, reply(@tid, "Hi."))
    fresh(bin, 2, @fresh, reply(@fresh, "Fresh."))

    on(bin, 2, "thread/resume", [
      j(%{id: 2, error: %{code: -32_600, message: "no rollout found for thread id #{@tid}"}})
    ])

    session = start(ctx)
    prompt(session, "hello")
    events = prompt(session, "again")

    assert %{"params" => %{"threadId" => @tid}} = request(bin, 2, "thread/resume")
    assert %{"params" => %{"model" => "gpt-6-luna"}} = request(bin, 2, "thread/start")

    assert %{
             "params" => %{
               "threadId" => @fresh,
               "items" => [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "hello"}]
                 },
                 %{
                   "type" => "message",
                   "role" => "assistant",
                   "content" => [%{"type" => "output_text", "text" => "Hi."}]
                 }
               ]
             }
           } = request(bin, 2, "thread/inject_items")

    assert %{"params" => %{"threadId" => @fresh, "input" => [%{"text" => "again"}]}} =
             request(bin, 2, "turn/start")

    assert [%{harness_session_id: @fresh, lost: true, cut: 0}] = of_type(events, :harness_session)

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Fresh."}]}] =
             messages(events)

    assert {:ok, %{harness_sessions: %{"codex" => {@fresh, 3}}}} =
             SessionFile.resume(ctx.sessions, ctx.work)
  end

  test "a switch to a codex model replays the history, tool calls too", %{bin: bin} = ctx do
    long = String.duplicate("i", 65)

    calls = [
      %Message.ToolCall{id: "call:1", name: "read", arguments: %{"path" => "a"}},
      %Message.ToolCall{id: long, name: "mcp/srv.tool", arguments: %{}}
    ]

    :ok = Fake.script(ctx.core, "m", [calls, ["Read it."]])
    fresh(bin, 1, @tid, reply(@tid, "Done."))

    session = start(ctx, "fake/m")
    prompt(session, "read a")
    :ok = Session.set_model(session, "codex/gpt-6-luna")
    events = prompt(session, "and now?")

    assert request(bin, 1, "thread/resume") == nil

    assert %{
             "params" => %{
               "items" => [
                 %{"type" => "message", "role" => "user"},
                 %{"type" => "function_call"} = read,
                 %{"type" => "function_call"} = mcp,
                 %{"type" => "function_call_output"} = read_result,
                 %{"type" => "function_call_output"} = mcp_result,
                 %{"type" => "message", "role" => "assistant"}
               ]
             }
           } = request(bin, 1, "thread/inject_items")

    assert %{"name" => "read", "arguments" => ~s({"path":"a"}), "call_id" => "h_" <> _ = id} =
             read

    assert byte_size(id) == 64
    assert read_result["call_id"] == id
    assert %{"name" => "mcp_srv_tool", "call_id" => "h_" <> _ = long_id} = mcp
    assert byte_size(long_id) == 64 and long_id != id
    assert mcp_result["call_id"] == long_id
    assert is_binary(read_result["output"])
    assert [%{lost: false, cut: 0}] = of_type(events, :harness_session)
  end

  test "an abort interrupts the turn and returns only when the program's group is gone",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")

    fresh(
      bin,
      1,
      @tid,
      [started(@tid, command("exec-1", %{status: "inProgress"}))],
      ~s{(trap '' TERM; exec sleep 30) &\necho $! > "#{pidfile}"\n}
    )

    on(bin, 1, "turn/interrupt", [
      j(%{id: 6, result: %{}}),
      turn_end(@tid, "interrupted")
    ])

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    pid = wait_for_pid(pidfile)

    # The program ends at its input's end after the interrupt; its child,
    # which ignores TERM, is gone only by the release of the group.
    :ok = Session.abort(session)
    refute os_alive?(pid)

    assert %{"params" => %{"threadId" => @tid, "turnId" => "turn1"}} =
             request(bin, 1, "turn/interrupt")

    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)
  end

  # Like codex: a command in a process group of its own, which the program
  # ends 3 s after the first TERM (the watchdog and the release each send
  # one); a KILL of the program's group would leave it running.
  defp own_group_command(pidfile, after_pid) do
    """
    perl -e 'setpgrp(0, 0); exec "sleep", "30"' </dev/null >/dev/null 2>&1 &
    c=$!
    trap 'trap "" TERM; sleep 3; kill -9 $c; exit 0' TERM
    echo $c > "#{pidfile}"
    #{after_pid}
    while :; do sleep 0.1; done
    """
  end

  test "an abort gives the program time to end its commands", %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    running = [started(@tid, command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, @tid, running, own_group_command(pidfile, ""))

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    pid = wait_for_pid(pidfile)

    :ok = Session.abort(session)
    refute os_alive?(pid)
    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)
  end

  test "a stream that ends while a command runs gives the program the same time",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    over_cap = ~s{perl -e 'print "x" x #{HarnessIO.line_max_bytes() + 1}, "\\n"'}
    running = [started(@tid, command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, @tid, running, own_group_command(pidfile, over_cap))

    session = start(ctx)
    :ok = Session.prompt(session, "wait")

    # The delivery release returns before the session gets the terminal.
    assert [%{stop_reason: :error}] = of_type(collect_until(:agent_end), :agent_end)
    refute os_alive?(wait_for_pid(pidfile))
  end

  test "a steer aborts the turn and starts a new one with the prompts", %{bin: bin} = ctx do
    fresh(bin, 1, @tid, [])
    resumed(bin, 2, @tid, reply(@tid, "Both."))
    fresh(bin, 2, @fresh, reply(@fresh, "Both."))

    session = start(ctx)
    :ok = Session.prompt(session, "first")
    collect_until(:harness_session)
    :ok = Session.steer(session, "second")

    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)
    events = collect_until(:agent_end)

    # The first thread made no message, so it is not resumed.
    assert request(bin, 2, "thread/resume") == nil

    assert %{"params" => %{"input" => [%{"text" => "first"}, %{"text" => "second"}]}} =
             request(bin, 2, "turn/start")

    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
  end

  test "a failed turn fails the turn, and a call with no result gets an aborted one",
       %{bin: bin} = ctx do
    fresh(bin, 1, @tid, [
      started(@tid, command("exec-a", %{status: "inProgress"})),
      started(@tid, command("exec-b", %{status: "inProgress"})),
      completed(
        @tid,
        command("exec-a", %{status: "failed", aggregatedOutput: "no", exitCode: 2})
      ),
      turn_end(@tid, "failed", "usage limit")
    ])

    events = prompt(start(ctx), "go")

    assert [%{stop_reason: :error, error: {:codex, "failed", "usage limit"}}] =
             of_type(events, :agent_end)

    assert [
             %{message: %Message{tool_call_id: "exec-a", is_error: true}},
             %{message: %Message{tool_call_id: "exec-b", is_error: true} = aborted}
           ] = of_type(events, :tool_execution_end)

    assert Message.text(aborted) == "aborted"
  end

  test "an approval request is accepted and any other server request gets an error",
       %{bin: bin, work: work} do
    fresh(
      bin,
      1,
      @tid,
      [
        j(%{id: 0, method: "item/commandExecution/requestApproval", params: %{threadId: @tid}}),
        j(%{id: "r", method: "item/fileChange/requestApproval", params: %{threadId: @tid}}),
        j(%{id: 7, method: "item/tool/requestUserInput", params: %{threadId: @tid}})
      ] ++ reply(@tid, "ok")
    )

    assert [{:harness_session, @tid, 0}, {:text_delta, "ok"}, {:done, _}] =
             run_direct([Message.user("go")], work)

    answers =
      for %{"id" => id} = line <- stdin(bin, 1), not is_map_key(line, "method"), do: {id, line}

    assert [
             {0, %{"result" => %{"decision" => "accept"}}},
             {"r", %{"result" => %{"decision" => "accept"}}},
             {7, %{"error" => %{"code" => -32_601}}}
           ] = answers
  end

  # Codex can run tool items side by side: the message of both calls
  # closes once, before the first result.
  test "two tool items that run together close one message", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("a", @done)),
      completed(@tid, command("b", @done)),
      turn_end(@tid, "completed")
    ])

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_result, "b", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)
  end

  # A message that closes while a call of the message before it still
  # runs waits for that call's result, so the session does not abort it.
  test "a message that closes before an earlier call's result waits for it",
       %{bin: bin, work: work} = ctx do
    lines = [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("a", @done)),
      delta(@tid, "msg_x", "x"),
      started(@tid, command("d", %{status: "inProgress"})),
      completed(@tid, command("d", @done)),
      completed(@tid, command("b", @done)),
      turn_end(@tid, "completed")
    ]

    fresh(bin, 1, @tid, lines)
    fresh(bin, 2, @tid, lines)

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:text_delta, "x"},
             {:tool_call, %{id: "d"}},
             {:tool_result, "b", {:ok, "out"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)

    # The same run in a session: every real result joins the transcript,
    # each before the next message.
    events = ctx |> start() |> prompt("go")

    assert [{"a", "out"}, {"b", "out"}, {"d", "out"}] =
             for(
               %{message: m} <- of_type(events, :tool_execution_end),
               do: {m.tool_call_id, Message.text(m)}
             )

    assert [
             %Message{role: :user},
             %Message{role: :assistant, content: [%{id: "a"}, %{id: "b"}]},
             %Message{role: :assistant, content: [%Message.Text{text: "x"}, %{id: "d"}]},
             # The session closes the turn with an empty message when the
             # turn ends right after a result (as before this change).
             %Message{role: :assistant, content: [], stop_reason: :end_turn}
           ] = messages(events)
  end

  # A result of a held message must not wait behind a later held message.
  test "a held result goes before a later message's end", %{bin: bin, work: work} = ctx do
    lines = [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("b", @done)),
      started(@tid, command("c", %{status: "inProgress"})),
      started(@tid, command("e", %{status: "inProgress"})),
      completed(@tid, command("c", @done)),
      started(@tid, command("d", %{status: "inProgress"})),
      completed(@tid, command("d", @done)),
      completed(@tid, command("e", @done)),
      completed(@tid, command("a", @done)),
      delta(@tid, "msg_y", "ok"),
      turn_end(@tid, "completed")
    ]

    fresh(bin, 1, @tid, lines)
    fresh(bin, 2, @tid, lines)

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "b", _},
             {:tool_call, %{id: "c"}},
             {:tool_call, %{id: "e"}},
             {:tool_result, "a", _},
             {:message_end, :tool_use, _},
             {:tool_result, "c", _},
             {:tool_result, "e", _},
             {:tool_call, %{id: "d"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", _},
             {:text_delta, "ok"},
             {:done, _}
           ] = run_direct([Message.user("go")], work)

    events = ctx |> start() |> prompt("go")

    assert ["out", "out", "out", "out", "out"] =
             for(%{message: m} <- of_type(events, :tool_execution_end), do: Message.text(m))
  end

  # A call that never completes: the turn's end sends what was held.
  test "the turn's end sends the held events", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("a", @done)),
      started(@tid, command("d", %{status: "inProgress"})),
      completed(@tid, command("d", @done)),
      turn_end(@tid, "completed")
    ])

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_call, %{id: "d"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)
  end

  # The program exits while events are held: they go out before the
  # error, so the session keeps the real result.
  test "an exit sends the held events before its error", %{bin: bin, work: work} do
    fresh(
      bin,
      1,
      @tid,
      [
        started(@tid, command("a", %{status: "inProgress"})),
        started(@tid, command("b", %{status: "inProgress"})),
        completed(@tid, command("a", @done)),
        started(@tid, command("d", %{status: "inProgress"})),
        completed(@tid, command("d", @done))
      ],
      "exit 3\n"
    )

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_call, %{id: "d"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:error, {:codex_exit, 3}}
           ] = run_direct([Message.user("go")], work)
  end

  test "a line over the cap sends the held events before its error", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("a", @done)),
      started(@tid, command("d", %{status: "inProgress"})),
      completed(@tid, command("d", @done)),
      String.duplicate("x", 16 * 1024 * 1024 + 1)
    ])

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_call, %{id: "d"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:error, {:line_over_limit, 16_777_216}}
           ] = run_direct([Message.user("go")], work)
  end

  test "a replayed call id and tool name keep to the API limits", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, reply(@tid, "ok"))

    ids = [
      String.duplicate("a", 63),
      String.duplicate("b", 64),
      String.duplicate("c", 65),
      "é",
      "e",
      ""
    ]

    names = [
      String.duplicate("l", 63),
      String.duplicate("n", 64),
      String.duplicate("m", 65),
      "é" <> String.duplicate("o", 64),
      "",
      "p"
    ]

    calls =
      Enum.zip_with(ids, names, &%Message.ToolCall{id: &1, name: &2, arguments: %{}})

    run_direct([%Message{role: :assistant, content: calls}, Message.user("go")], work)
    %{"params" => %{"items" => items}} = request(bin, 1, "thread/inject_items")
    [a63, b64 | _] = ids
    assert [^a63, ^b64, id65, id_multibyte, "e", "h_" <> _] = Enum.map(items, & &1["call_id"])
    assert "h_" <> _ = id65
    assert "h_" <> _ = id_multibyte
    assert byte_size(id65) == 64
    assert byte_size(id_multibyte) == 64
    assert id65 != id_multibyte

    assert Enum.map(items, & &1["name"]) == [
             String.duplicate("l", 63),
             String.duplicate("n", 64),
             String.duplicate("m", 64),
             "_" <> String.duplicate("o", 63),
             "_",
             "p"
           ]
  end

  test "a message with no deltas gives its text whole", %{bin: bin, work: work} do
    item = %{type: "agentMessage", id: "msg_1", text: "Whole."}
    fresh(bin, 1, @tid, [completed(@tid, item), turn_end(@tid, "completed")])

    assert [{:harness_session, @tid, 0}, {:text_delta, "Whole."}, {:done, _}] =
             run_direct([Message.user("go")], work)
  end

  test "the replay keeps the newest messages within 400,000 bytes and never starts at a result",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, reply(@tid, "ok"))
    big = String.duplicate("x", 150_000)
    call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}

    history = [
      %Message{role: :user, content: [%Message.Text{text: "old " <> big}]},
      %Message{role: :assistant, content: [%Message.Text{text: big <> big}, call]},
      %Message{role: :tool_result, tool_call_id: "c1", content: [%Message.Text{text: big}]},
      %Message{role: :assistant, content: [%Message.Text{text: "tail"}]},
      Message.user("go")
    ]

    # The result and the tail fit; the assistant message with the call does
    # not, so the replay starts after the result, at the tail.
    assert [{:harness_session, @tid, 3} | _] = run_direct(history, work)

    assert %{"params" => %{"items" => [%{"content" => [%{"text" => "tail"}]}]}} =
             request(bin, 1, "thread/inject_items")
  end

  test "a response error fails the stream with the method and the message",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [j(%{id: 3, error: %{code: -1, message: "bad model"}})])

    assert [{:error, {:codex, "thread/start", "bad model"}}] =
             run_direct([Message.user("go")], work)
  end

  test "a program that exits before the turn ends is an error", %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [], "exit 3\n")

    assert [{:error, {:codex_exit, 3}}] =
             run_direct([Message.user("go")], work)
  end
end
