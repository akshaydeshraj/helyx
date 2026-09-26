defmodule Helyx.Provider.ClaudeCodeTest do
  # A fake `claude` on PATH replays stream-json lines in the shapes that
  # `docs/research/claude-code-stream-json.md` records. Run N saves its
  # arguments to `args.N` and its stdin to `stdin.N`, then runs `run.N`.
  # PATH is global, so this module is not async.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.{ClaudeCode, Fake}

  @sid "4b3c2d1e-0000-4000-8000-000000000001"
  @fresh "4b3c2d1e-0000-4000-8000-000000000002"

  @fake """
  #!/bin/sh
  d=$(dirname "$0")
  n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
  echo $n > "$d/count"
  for a in "$@"; do printf '%s\\n' "$a"; done > "$d/args.$n"
  cat > "$d/stdin.$n"
  . "$d/run.$n"
  """

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "claude"), @fake)
    File.chmod!(Path.join(bin, "claude"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [ClaudeCode, Fake]})
    work = Path.join(tmp, "work")
    File.mkdir_p!(work)
    %{core: core, bin: bin, work: work, sessions: Path.join(tmp, "sessions")}
  end

  # Stream-json lines

  # Runs the stream in the test process, without a session.
  defp run_direct(messages, work, opts \\ []) do
    {:ok, stream} =
      ClaudeCode.stream("haiku", %Helyx.Context{messages: messages}, [cwd: work] ++ opts)

    Enum.to_list(stream)
  end

  defp j(map), do: JSON.encode!(map)

  defp init(sid) do
    j(%{
      type: "system",
      subtype: "init",
      session_id: sid,
      cwd: "/work",
      model: "claude-haiku-4-5-20251001",
      tools: ["Bash", "Read"],
      permissionMode: "bypassPermissions",
      uuid: "u1"
    })
  end

  defp delta(sid, text) do
    j(%{
      type: "stream_event",
      event: %{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: text}},
      session_id: sid,
      parent_tool_use_id: nil,
      uuid: "u2"
    })
  end

  defp assistant(sid, block) do
    j(%{
      type: "assistant",
      message: %{
        id: "msg_1",
        type: "message",
        role: "assistant",
        model: "claude-haiku-4-5-20251001",
        content: [block],
        stop_reason: nil,
        usage: %{input_tokens: 12, output_tokens: 7}
      },
      parent_tool_use_id: nil,
      session_id: sid,
      uuid: "u3"
    })
  end

  defp tool_use(sid, id, input),
    do: assistant(sid, %{type: "tool_use", id: id, name: "Bash", input: input})

  defp tool_result(sid, id, content) do
    j(%{
      type: "user",
      message: %{
        role: "user",
        content: [%{tool_use_id: id, type: "tool_result", content: content}]
      },
      parent_tool_use_id: nil,
      session_id: sid,
      uuid: "u4",
      tool_use_result: %{stdout: content}
    })
  end

  defp result(sid, text, num_turns \\ 1) do
    j(%{
      type: "result",
      subtype: "success",
      is_error: false,
      result: text,
      stop_reason: if(num_turns > 0, do: "end_turn"),
      num_turns: num_turns,
      usage: %{input_tokens: 12, output_tokens: 7},
      session_id: sid,
      total_cost_usd: 0.001,
      permission_denials: []
    })
  end

  defp lost(sid) do
    j(%{
      type: "result",
      subtype: "error_during_execution",
      is_error: true,
      num_turns: 0,
      session_id: sid,
      errors: ["No conversation found with session ID: #{sid}"]
    })
  end

  # A reply of one text, as the program streams it.
  defp reply(sid, text) do
    [init(sid), delta(sid, text), assistant(sid, %{type: "text", text: text}), result(sid, text)]
  end

  # Writes run `n`: its output lines, then `tail` as shell code.
  defp scenario(bin, n, lines, tail \\ "") do
    File.write!(Path.join(bin, "out.#{n}"), Enum.map(lines, &[&1, "\n"]))
    File.write!(Path.join(bin, "run.#{n}"), ~s(cat "$d/out.#{n}"\n) <> tail)
  end

  defp args(bin, n),
    do: bin |> Path.join("args.#{n}") |> File.read!() |> String.split("\n", trim: true)

  defp stdin(bin, n) do
    bin
    |> Path.join("stdin.#{n}")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      5_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp start(ctx, model \\ "claude-code/haiku") do
    {:ok, session} =
      Session.start(ctx.core, model: model, cwd: ctx.work, sessions_dir: ctx.sessions)

    :ok = Session.subscribe(session)
    session
  end

  defp prompt(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:agent_end)
  end

  defp messages(events), do: for(%Event{type: :message_end, data: %{message: m}} <- events, do: m)
  defp of_type(events, type), do: for(%Event{type: ^type, data: data} <- events, do: data)

  @moduletag :tmp_dir

  test "a turn: text, tool calls, and tool results join the transcript, and the id is stored",
       %{bin: bin} = ctx do
    scenario(bin, 1, [
      init(@sid),
      delta(@sid, "I will list."),
      assistant(@sid, %{type: "text", text: "I will list."}),
      tool_use(@sid, "toolu_01", %{"command" => "ls"}),
      tool_result(@sid, "toolu_01", "a.txt"),
      delta(@sid, "One file."),
      assistant(@sid, %{type: "text", text: "One file."}),
      result(@sid, "One file.", 2)
    ])

    session = start(ctx)
    events = prompt(session, "list the files")

    assert "--permission-mode" in args(bin, 1)
    assert "bypassPermissions" in args(bin, 1)
    assert "--model=haiku" in args(bin, 1)
    refute Enum.any?(args(bin, 1), &String.starts_with?(&1, "--resume"))

    assert [%{"type" => "user", "message" => %{"content" => [%{"text" => "list the files"}]}}] =
             stdin(bin, 1)

    assert [%{provider: "claude-code", harness_session_id: @sid, lost: false, cut: 0}] =
             of_type(events, :harness_session)

    call = %Message.ToolCall{id: "toolu_01", name: "Bash", arguments: %{"command" => "ls"}}

    assert [
             %Message{role: :user},
             %Message{role: :assistant, stop_reason: :tool_use, model: "claude-code/haiku"} =
               first,
             %Message{role: :assistant, stop_reason: :end_turn} = last
           ] = messages(events)

    assert first.content == [%Message.Text{text: "I will list."}, call]
    assert last.content == [%Message.Text{text: "One file."}]
    assert [%{tool_call: ^call}] = of_type(events, :tool_execution_start)

    assert [%{message: %Message{role: :tool_result, tool_call_id: "toolu_01", is_error: false}}] =
             of_type(events, :tool_execution_end)

    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)

    assert {:ok, %{harness_sessions: %{"claude-code" => {@sid, 1}}}} =
             Session.File.resume(ctx.sessions, ctx.work)
  end

  test "a tool result over the limits arrives cut, with the notice", %{bin: bin, work: work} do
    big = String.duplicate("x\n", 3_000)

    scenario(bin, 1, [
      init(@sid),
      tool_use(@sid, "toolu_01", %{"command" => "seq"}),
      tool_result(@sid, "toolu_01", big),
      result(@sid, "Done.", 2)
    ])

    assert [text] = for({:tool_result, "toolu_01", {:ok, t}} <- run_direct([], work), do: t)
    assert text == Helyx.Text.truncate(big, :tail)
    assert text =~ "[truncated: showing lines 1001-3000 of 3000]"
  end

  test "a later turn and a resumed session pass the id and send only the prompt",
       %{bin: bin} = ctx do
    scenario(bin, 1, reply(@sid, "Hi."))
    scenario(bin, 2, reply(@sid, "Again."))
    scenario(bin, 3, reply(@sid, "Back."))

    session = start(ctx)
    prompt(session, "hello")
    events = prompt(session, "again")

    assert "--resume=#{@sid}" in args(bin, 2)
    assert [%{"message" => %{"content" => [%{"text" => "again"}]}}] = stdin(bin, 2)
    assert of_type(events, :harness_session) == []

    GenServer.stop(Session.pid(session))
    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    :ok = Session.subscribe(session)
    prompt(session, "back")

    assert "--resume=#{@sid}" in args(bin, 3)
    assert [%{"message" => %{"content" => [%{"text" => "back"}]}}] = stdin(bin, 3)
  end

  test "a lost harness session starts a fresh one with the transcript replayed",
       %{bin: bin} = ctx do
    scenario(bin, 1, reply(@sid, "Hi."))
    scenario(bin, 2, [lost(@sid)], "exit 1\n")
    scenario(bin, 3, [init(@fresh), result(@fresh, "", 0) | reply(@fresh, "Fresh.")])

    session = start(ctx)
    prompt(session, "hello")
    events = prompt(session, "again")

    assert "--resume=#{@sid}" in args(bin, 2)
    refute Enum.any?(args(bin, 3), &String.starts_with?(&1, "--resume"))

    assert [
             %{
               "type" => "user",
               "shouldQuery" => false,
               "message" => %{"content" => [%{"text" => "hello"}]}
             },
             %{
               "type" => "assistant",
               "message" => %{"content" => [%{"type" => "text", "text" => "Hi."}]}
             },
             %{
               "type" => "user",
               "message" => %{"content" => [%{"text" => "again"}]} = prompt_line
             }
           ] = stdin(bin, 3)

    refute Map.has_key?(prompt_line, "shouldQuery")

    assert [%{harness_session_id: @fresh, lost: true, cut: 0}] = of_type(events, :harness_session)

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Fresh."}]}] =
             messages(events)

    assert {:ok, %{harness_sessions: %{"claude-code" => {@fresh, 3}}}} =
             Session.File.resume(ctx.sessions, ctx.work)
  end

  test "a fresh session aborted before its first message is not resumed, in memory or after a restart",
       %{bin: bin} = ctx do
    scenario(bin, 1, reply(@sid, "Hi."))
    scenario(bin, 2, [lost(@sid)], "exit 1\n")
    scenario(bin, 3, [init(@fresh)], "sleep 30\n")
    scenario(bin, 4, [init(@fresh)], "sleep 30\n")
    scenario(bin, 5, reply(@fresh, "Fresh."))

    session = start(ctx)
    prompt(session, "hello")
    :ok = Session.prompt(session, "again")
    collect_until(:harness_session)
    :ok = Session.abort(session)
    collect_until(:agent_end)

    :ok = Session.prompt(session, "more")
    collect_until(:harness_session)
    :ok = Session.abort(session)
    collect_until(:agent_end)
    refute Enum.any?(args(bin, 4), &String.starts_with?(&1, "--resume"))
    assert %{"message" => %{"content" => [%{"text" => "hello"}]}} = hd(stdin(bin, 4))

    GenServer.stop(Session.pid(session))
    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    :ok = Session.subscribe(session)
    prompt(session, "last")

    refute Enum.any?(args(bin, 5), &String.starts_with?(&1, "--resume"))
    assert %{"message" => %{"content" => [%{"text" => "hello"}]}} = hd(stdin(bin, 5))
  end

  test "a switch to a claude-code model replays the history, tool calls too", %{bin: bin} = ctx do
    call = %Message.ToolCall{id: "call:1", name: "read", arguments: %{"path" => "a"}}
    :ok = Fake.script(ctx.core, "m", [[call], ["Read it."]])
    scenario(bin, 1, reply(@sid, "Done."))

    session = start(ctx, "fake/m")
    prompt(session, "read a")
    :ok = Session.set_model(session, "claude-code/haiku")
    events = prompt(session, "and now?")

    refute Enum.any?(args(bin, 1), &String.starts_with?(&1, "--resume"))

    assert [
             %{"shouldQuery" => false, "message" => %{"content" => [%{"text" => "read a"}]}},
             %{
               "type" => "assistant",
               "message" => %{"content" => [%{"type" => "tool_use"} = use]}
             },
             %{"shouldQuery" => false, "message" => %{"content" => [result]}},
             %{"type" => "assistant", "message" => %{"content" => [%{"text" => "Read it."}]}},
             %{"message" => %{"content" => [%{"text" => "and now?"}]}}
           ] = stdin(bin, 1)

    assert use == %{
             "type" => "tool_use",
             "id" => "call_1",
             "name" => "read",
             "input" => %{"path" => "a"}
           }

    assert %{"type" => "tool_result", "tool_use_id" => "call_1", "is_error" => true} = result
    assert [%{lost: false, cut: 0}] = of_type(events, :harness_session)
  end

  test "a steer aborts the harness turn and starts a new one with the prompts",
       %{bin: bin} = ctx do
    scenario(bin, 1, [init(@sid)], "sleep 60\n")
    scenario(bin, 2, reply(@fresh, "Both."))

    session = start(ctx)
    :ok = Session.prompt(session, "first")
    collect_until(:harness_session)
    :ok = Session.steer(session, "second")

    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)
    events = collect_until(:agent_end)

    assert [%{"message" => %{"content" => [%{"text" => "first"}, %{"text" => "second"}]}}] =
             stdin(bin, 2)

    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
  end

  test "an abort returns only when the program's group is gone", %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    scenario(bin, 1, [init(@sid)], ~s(echo $$ > "#{pidfile}"\ntrap '' TERM\nsleep 60\n))

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:harness_session)
    pid = wait_for_pid(pidfile)

    started = System.monotonic_time(:millisecond)
    :ok = Session.abort(session)
    # The program ignores TERM: only the KILL after the grace ends it.
    assert System.monotonic_time(:millisecond) - started >= 500
    refute os_alive?(pid)
  end

  test "an error result fails the turn, and a call with no result gets an aborted one",
       %{bin: bin} = ctx do
    error =
      j(%{
        type: "result",
        subtype: "error_max_turns",
        is_error: true,
        num_turns: 3,
        errors: ["too many"]
      })

    scenario(
      bin,
      1,
      [
        init(@sid),
        tool_use(@sid, "toolu_a", %{}),
        tool_use(@sid, "toolu_b", %{}),
        tool_result(@sid, "toolu_a", "done"),
        error
      ],
      "exit 1\n"
    )

    events = prompt(start(ctx), "go")

    assert [%{stop_reason: :error, error: {:claude_code, "error_max_turns", "too many"}}] =
             of_type(events, :agent_end)

    assert [
             %{message: %Message{tool_call_id: "toolu_a", is_error: false}},
             %{message: %Message{tool_call_id: "toolu_b", is_error: true} = aborted}
           ] = of_type(events, :tool_execution_end)

    assert Message.text(aborted) == "aborted"
  end

  describe "the replay cap" do
    test "keeps the newest messages within 400,000 bytes and never starts at a result",
         %{bin: bin, work: work} do
      scenario(bin, 1, reply(@sid, "ok"))
      big = String.duplicate("x", 150_000)
      call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}

      messages = [
        Message.user(big),
        %Message{role: :assistant, content: [%Message.Text{text: big}]},
        Message.user("run it"),
        %Message{role: :assistant, content: [call]},
        Message.tool_result(call, {:ok, big}),
        %Message{role: :assistant, content: [%Message.Text{text: big}]},
        Message.user("next")
      ]

      assert [{:harness_session, @sid, 2} | _] = run_direct(messages, work)

      assert [
               %{"message" => %{"content" => [%{"text" => "run it"}]}},
               %{"type" => "assistant"},
               %{"message" => %{"content" => [%{"type" => "tool_result"}]}},
               %{"type" => "assistant"},
               %{"message" => %{"content" => [%{"text" => "next"}]}}
             ] = stdin(bin, 1)
    end

    test "history lines of exactly 400,000 bytes all go; one byte more cuts",
         %{bin: bin, work: work} do
      # The line sizes come from the same shapes the provider encodes.
      size = fn map -> byte_size(j(map)) + 1 end
      user = String.duplicate("é", 1_000)

      user_line =
        size.(%{
          type: "user",
          shouldQuery: false,
          message: %{role: "user", content: [%{type: "text", text: user}]}
        })

      assistant = fn text ->
        size.(%{
          type: "assistant",
          message: %{role: "assistant", content: [%{type: "text", text: text}]}
        })
      end

      fill = 400_000 - user_line - (assistant.("x") - 1)

      scenario(bin, 1, reply(@sid, "ok"))

      # Each case is run 1 of the fake again.
      for {extra, cut} <- [{-1, 0}, {0, 0}, {1, 1}] do
        File.rm(Path.join(bin, "count"))
        text = String.duplicate("x", fill + extra)
        assert assistant.(text) + user_line == 400_000 + extra

        messages = [
          Message.user(user),
          %Message{role: :assistant, content: [%Message.Text{text: text}]},
          Message.user("next")
        ]

        assert [{:harness_session, @sid, ^cut} | _] = run_direct(messages, work)
        assert length(stdin(bin, 1)) == 3 - cut
      end
    end

    test "a cut that lands after a tool call drops its result too", %{bin: bin, work: work} do
      scenario(bin, 1, reply(@sid, "ok"))

      call = %Message.ToolCall{
        id: "c1",
        name: "bash",
        arguments: %{"x" => String.duplicate("z", 100_000)}
      }

      messages = [
        Message.user("go"),
        %Message{role: :assistant, content: [call]},
        Message.tool_result(call, {:ok, String.duplicate("y", 100_000)}),
        %Message{
          role: :assistant,
          content: [%Message.Text{text: String.duplicate("w", 250_000)}]
        },
        Message.user("next")
      ]

      assert [{:harness_session, @sid, 3} | _] = run_direct(messages, work)

      assert [%{"type" => "assistant"}, %{"message" => %{"content" => [%{"text" => "next"}]}}] =
               stdin(bin, 1)
    end
  end

  test "a program that does not start ends the stream with its text cut at 2,000 bytes",
       %{work: work} do
    # A path of 3,200 bytes: the watchdog's text repeats it, so the text is
    # over the cut.
    missing = Path.join([work | List.duplicate(String.duplicate("d", 200), 16)])

    assert [{:error, {:not_started, text}}] = run_direct([Message.user("go")], missing)
    assert byte_size(text) == 2_000
  end

  test "lines of 16 MiB and one byte under are read", %{bin: bin, work: work} do
    scenario(bin, 1, reply(@sid, "ok"))

    for bytes <- [16_777_215, 16_777_216] do
      File.rm(Path.join(bin, "count"))

      File.write!(
        Path.join(bin, "run.1"),
        ~s(head -c #{bytes} /dev/zero | tr '\\0' 'x'; echo; cat "$d/out.1"\n)
      )

      assert [{:harness_session, @sid, 0}, {:text_delta, "ok"}, {:done, _}] =
               run_direct([Message.user("hi")], work)
    end
  end

  # A program can write faster than the stream reads. Waits in the stream's
  # own process until the exit wait of the terminal has passed, then queues
  # `n` chunks of stdout from its port: none of them may be read.
  defp queue_stdout_past_deadline(n) do
    port = Enum.find(Port.list(), &(Port.info(&1, :connected) == {:connected, self()}))
    Process.sleep(5_100)
    for _ <- 1..n, do: send(self(), {port, {:data, "x\n"}})
  end

  test "stdout queued past the exit deadline does not hold the terminal",
       %{bin: bin, work: work} do
    scenario(bin, 1, reply(@sid, "ok"), "sleep 30\n")

    {:ok, stream} =
      ClaudeCode.stream("haiku", %Helyx.Context{messages: [Message.user("hi")]}, cwd: work)

    events =
      Enum.map(stream, fn
        {:text_delta, _text} = event -> tap(event, fn _ -> queue_stdout_past_deadline(1_000) end)
        event -> event
      end)

    assert [_, {:text_delta, "ok"}, {:done, %{stop_reason: :end_turn}}] = events
    assert {:message_queue_len, queued} = Process.info(self(), :message_queue_len)
    assert queued >= 1_000
  end

  test "output after the result is not read, and the exit wait runs once from the result",
       %{bin: bin, work: work} do
    # 17 MB after the result, then output each second for 10 s: neither the
    # line cap nor a new exit wait applies.
    scenario(
      bin,
      1,
      [init(@sid), delta(@sid, "ok"), result(@sid, "ok")],
      ~s(head -c 17000000 /dev/zero | tr '\\0' 'x'\nfor i in 1 2 3 4 5 6 7 8 9 10; do echo junk; sleep 1; done\n)
    )

    started = System.monotonic_time(:millisecond)

    assert [{:harness_session, @sid, 0}, {:text_delta, "ok"}, {:done, %{stop_reason: :end_turn}}] =
             run_direct([Message.user("hi")], work)

    assert (System.monotonic_time(:millisecond) - started) in 5_000..7_999
  end

  test "a lost-session result whose program does not exit starts the fresh run at the deadline",
       %{bin: bin, work: work} do
    scenario(bin, 1, [lost(@sid)], "sleep 30\n")
    scenario(bin, 2, reply(@fresh, "Fresh."))

    started = System.monotonic_time(:millisecond)

    assert [{:harness_session, @fresh, 0}, {:text_delta, "Fresh."}, {:done, _}] =
             run_direct([Message.user("hi")], work, harness_session_id: @sid)

    assert (System.monotonic_time(:millisecond) - started) in 5_000..7_999
  end

  test "a line one byte over 16 MiB with its newline in one write is an error",
       %{bin: bin, work: work} do
    File.write!(Path.join(bin, "line"), [String.duplicate("x", 16_777_217), "\n"])
    File.write!(Path.join(bin, "run.1"), ~s(cat "$d/line"\n))

    assert [{:error, {:line_over_limit, 16_777_216}}] = run_direct([Message.user("hi")], work)
  end

  test "the program's error text and subtype are cut at 2,000 bytes, not in a character",
       %{bin: bin, work: work} do
    long = "a" <> String.duplicate("é", 1_000)

    # {text of the errors and of the subtype, bytes kept of each}
    for {text, want} <- [
          {String.duplicate("a", 1_999), 1_999},
          {String.duplicate("a", 2_000), 2_000},
          {String.duplicate("a", 2_001), 2_000},
          {long, 1_999}
        ] do
      File.rm(Path.join(bin, "count"))
      error = j(%{type: "result", subtype: text, is_error: true, num_turns: 1, errors: [text]})
      scenario(bin, 1, [init(@sid), error], "exit 1\n")

      assert [_, {:error, {:claude_code, subtype, text}}] =
               run_direct([Message.user("hi")], work)

      assert {byte_size(text), byte_size(subtype)} == {want, want}
      assert String.valid?(text) and String.valid?(subtype)
    end
  end

  test "a line over 16 MiB ends the stream with an error", %{bin: bin, work: work} do
    File.write!(Path.join(bin, "run.1"), ~s(head -c 16777217 /dev/zero | tr '\\0' 'x'\n))

    assert [{:error, {:line_over_limit, 16_777_216}}] =
             run_direct([Message.user("hi")], work)
  end
end
