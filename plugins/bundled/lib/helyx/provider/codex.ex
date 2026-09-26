defmodule Helyx.Provider.Codex do
  # The TERM grace of the release: codex ends its commands itself on TERM.
  @term_grace_ms 5_000

  alias Helyx.HarnessIO

  @moduledoc """
  A harness provider that drives the unmodified Codex program through its
  app server, `codex app-server`, with JSON-RPC lines over stdio (ADR
  0002). The model ref is `codex/<model>`, where `<model>` is a model id of
  `codex`, such as `gpt-6-luna`.

  One harness turn is one run of `codex app-server` from `PATH` in the
  session's working directory, in its own process group under the
  watchdog of `Helyx.Watchdog`, with open input. The session runs the
  stream as a Task of the hands; the run holds its groups with
  `Helyx.Tool.hold/1`, and the hands release them through `release/3`, so
  an abort returns only when the program's group is gone (ADR 0004). The
  Task traps exits: on the hands' `:shutdown` it sends `turn/interrupt`
  and waits up to 1,000 ms for the turn to end before it exits. The
  watchdog, when the port closes, and every release but a retry TERM the
  program's group and wait up to #{@term_grace_ms} ms for it to go before
  the KILL:
  codex runs every command in a process group of its own and ends them
  itself on TERM, but a KILL leaves them running. Threads
  run with the approval policy `never` and the sandbox
  `danger-full-access`, the same trust as the bash tool. A command or
  file change approval request is accepted all the same; every other
  request from the server gets a JSON-RPC error. The program uses its own
  tools; Helyx tools are not offered. Its stderr is dropped.

  With the `:harness_session_id` option the run resumes that thread and
  sends only the prompt: the user messages at the end of the transcript.
  Without it, or when the program has no such thread, the run starts a
  fresh thread and first gives it the rest of the transcript with
  `thread/inject_items`. The replay keeps the newest messages within
  #{HarnessIO.replay_max_bytes()} bytes of items, and it never starts at a
  tool result. The `{:harness_session, id, cut}` event of a fresh thread
  gives its id and the number of messages left out.

  Assistant text and reasoning stream as deltas. A tool item (a command,
  a file change, a tool of an MCP server, and the like) is a tool call
  when it starts and a tool result when it completes, and a `message_end`
  closes the assistant message before the result. A stdout line over
  #{HarnessIO.line_max_bytes()} bytes ends the stream with an error. The
  protocol facts are in `docs/research/codex-app-server.md`.
  """

  @behaviour Helyx.Provider

  alias Helyx.Message

  defmodule State do
    @moduledoc false
    # One run of the program. `resume` is the thread id to resume, or nil.
    # `history` is the transcript before the prompt. `thread` and `turn`
    # are the ids the program gave. `started` holds the ids of the tool
    # items that have a tool call, and `streamed` the ids of the messages
    # whose text came as deltas. `calls` holds the ids of the tool calls of
    # the message that no `message_end` closed yet; `waiting` the ids of
    # the calls of sent messages with no result yet; `held` the events that
    # wait for those results (see `in_order/2`).
    @enforce_keys [:model, :cwd, :resume, :history, :prompt]
    defstruct [
      :model,
      :cwd,
      :resume,
      :history,
      :prompt,
      :port,
      :thread,
      :turn,
      :terminal,
      :deadline,
      buffer: [],
      size: 0,
      usage: %{},
      done?: false,
      calls: [],
      waiting: MapSet.new(),
      held: :queue.new(),
      started: MapSet.new(),
      streamed: MapSet.new()
    ]
  end

  # Request ids: one of each request per run.
  @initialize 1
  @resume 2
  @start 3
  @inject 4
  @turn 5
  @interrupt 6
  @methods %{
    @initialize => "initialize",
    @resume => "thread/resume",
    @start => "thread/start",
    @inject => "thread/inject_items",
    @turn => "turn/start",
    @interrupt => "turn/interrupt"
  }

  @lost "no rollout found"
  # The wait for the end of the turn after `turn/interrupt`, within the
  # hands' shutdown grace.
  @interrupt_wait_ms 1_000
  # Item types that run something (see the research note).
  @tool_item_types ~w(commandExecution fileChange mcpToolCall dynamicToolCall collabAgentToolCall
            webSearch imageView imageGeneration)
  @trust %{approvalPolicy: "never", sandbox: "danger-full-access"}

  @impl true
  def id, do: "codex"

  @impl true
  def kind, do: :harness

  # A delivery TERMs first too: the stream can end (a line over the cap,
  # the exit wait) while codex still runs a command.
  @impl true
  def release(handles, :deliver, deadline), do: release(handles, :cancel, deadline)

  def release(handles, mode, deadline),
    do: Helyx.Watchdog.release(handles, mode, deadline, grace_ms: @term_grace_ms)

  @impl true
  def stream(model, %Helyx.Context{messages: messages}, opts) do
    case System.find_executable("codex") do
      nil ->
        {:error, "codex not found on PATH"}

      exe ->
        {prompt, history} = HarnessIO.split_prompt(messages)

        state = %State{
          model: model,
          cwd: Keyword.fetch!(opts, :cwd),
          resume: opts[:harness_session_id],
          history: history,
          prompt: prompt
        }

        {:ok, Stream.resource(fn -> start(exe, state) end, &next/1, &HarnessIO.stop/1)}
    end
  end

  defp start(exe, state) do
    Process.flag(:trap_exit, true)
    argv = ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), exe, "app-server"]

    state = HarnessIO.start(argv, state.cwd, :open, state, grace_ms: @term_grace_ms)

    if state.terminal == nil,
      do: request(state, @initialize, %{clientInfo: %{name: "helyx", version: "0"}})

    state
  end

  defp next(%{done?: true} = state), do: HarnessIO.drain(state)

  # The port's own exit signal is not a stop: its exit status says it all.
  # Any other exit signal is the hands' shutdown (or their death).
  defp next(%{port: port} = state) do
    if HarnessIO.overdue?(state),
      do: {[], %{state | done?: true}},
      else: receive_next(port, state)
  end

  defp receive_next(port, state) do
    receive do
      {^port, {:data, data}} -> data |> HarnessIO.lines(state, &in_order/2) |> settle()
      {^port, {:exit_status, status}} -> settle(exited(status, %{state | port: nil}))
      {:EXIT, ^port, _reason} -> {[], state}
      {:EXIT, _from, reason} -> interrupt(state, reason)
    after
      HarnessIO.wait(state) -> {[], %{state | done?: true}}
    end
  end

  defp exited(_status, %{terminal: terminal} = state) when terminal != nil,
    do: {[], %{state | done?: true}}

  defp exited(status, state),
    do: {[], %{state | done?: true, terminal: {:error, {:codex_exit, status}}}}

  # Asks the program to stop a running turn, waits for its end within
  # `@interrupt_wait_ms`, and exits. The closed port then ends the program.
  defp interrupt(%{turn: turn, terminal: nil, port: port} = state, reason)
       when is_binary(turn) and port != nil do
    request(state, @interrupt, %{threadId: state.thread, turnId: turn})
    await_end(state, System.monotonic_time(:millisecond) + @interrupt_wait_ms)
    exit(reason)
  end

  defp interrupt(_state, reason), do: exit(reason)

  defp await_end(%{port: port} = state, deadline) do
    if HarnessIO.overdue?(deadline), do: :ok, else: receive_end(port, state, deadline)
  end

  defp receive_end(port, state, deadline) do
    receive do
      {^port, {:data, data}} ->
        {_events, state} = HarnessIO.lines(data, state, &translate/2)
        if state.terminal, do: :ok, else: await_end(state, deadline)

      {^port, {:exit_status, _status}} ->
        :ok
    after
      HarnessIO.remaining(deadline) -> :ok
    end
  end

  # Output

  # At any terminal (the turn's end, an error, the program's exit, a line
  # over the cap), every held event goes out after the events of the chunk.
  defp settle({events, %{terminal: nil} = state}), do: {events, state}

  defp settle({events, state}) do
    {out, state} = :queue.fold(&emit/2, {[], %{state | held: :queue.new()}}, state.held)
    {events ++ Enum.reverse(out), state}
  end

  # The session gives every call that is still open an `aborted` result at
  # a `message_end` (`Helyx.Provider`). Codex runs tool items side by side,
  # so a call of a sent message can still run when the next message closes.
  # Such a `message_end`, and every event after it, is held until the
  # results of the sent calls are out; a result of a sent call goes out at
  # once. At a terminal `settle/1` sends every held event, in order.
  defp in_order(object, state) do
    {events, state} = translate(object, state)
    {out, state} = Enum.reduce(events, {[], state}, &order_one/2)
    {Enum.reverse(out), state}
  end

  defp order_one(event, {out, state}) do
    cond do
      waiting_result?(event, state) -> flush(emit(event, {out, state}))
      :queue.is_empty(state.held) and not blocked?(event, state) -> emit(event, {out, state})
      true -> {out, %{state | held: hold(event, state.held)}}
    end
  end

  # A held result goes right after its own `message_end` and the results
  # there, so a later `message_end` cannot hold it back. A result with no
  # held `message_end`, such as a repeat, goes to the end. Each insert
  # costs O(held); the held events have no bound (row "Codex held events").
  defp hold({:tool_result, id, _result} = event, held) do
    {before, rest} = Enum.split_while(:queue.to_list(held), &(not closes?(&1, id)))

    case rest do
      [close | tail] ->
        {results, later} = Enum.split_while(tail, &match?({:tool_result, _, _}, &1))
        :queue.from_list(before ++ [close | results] ++ [event | later])

      [] ->
        :queue.in(event, held)
    end
  end

  defp hold(event, held), do: :queue.in(event, held)

  defp closes?({:close, ids, _event}, id), do: id in ids
  defp closes?(_event, _id), do: false

  defp waiting_result?({:tool_result, id, _result}, state), do: MapSet.member?(state.waiting, id)
  defp waiting_result?(_event, _state), do: false

  defp blocked?({:close, _ids, _event}, state), do: MapSet.size(state.waiting) > 0
  defp blocked?(_event, _state), do: false

  defp emit({:close, ids, event}, {out, state}),
    do: {[event | out], %{state | waiting: MapSet.new(ids)}}

  defp emit({:tool_result, id, _result} = event, {out, state}),
    do: {[event | out], %{state | waiting: MapSet.delete(state.waiting, id)}}

  defp emit(event, {out, state}), do: {[event | out], state}

  # Sends the held events from the front up to a `message_end` that waits.
  defp flush({out, state}) do
    case :queue.out(state.held) do
      {{:value, event}, rest} ->
        if blocked?(event, state),
          do: {out, state},
          else: flush(emit(event, {out, %{state | held: rest}}))

      {:empty, _rest} ->
        {out, state}
    end
  end

  # A request of the server (it has an id and a method).
  defp translate(%{"id" => id, "method" => method}, state) do
    answer =
      if method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"],
        do: %{result: %{decision: "accept"}},
        else: %{error: %{code: -32_601, message: "not supported by Helyx"}}

    send_line(state, Map.put(answer, :id, id))
    {[], state}
  end

  defp translate(%{"id" => @initialize, "result" => _}, state) do
    send_line(state, %{method: "initialized"})

    if state.resume do
      params = Map.merge(thread_params(state), %{threadId: state.resume, excludeTurns: true})
      request(state, @resume, params)
      {[], state}
    else
      start_thread(state)
    end
  end

  # The program has no such thread: a fresh one starts on the same run.
  defp translate(%{"id" => @resume, "error" => %{"message" => @lost <> _}}, state),
    do: start_thread(state)

  defp translate(%{"id" => @resume, "result" => _}, state) do
    start_turn(%{state | thread: state.resume})
  end

  defp translate(%{"id" => @start, "result" => %{"thread" => %{"id" => thread}}}, state)
       when is_binary(thread) do
    state = %{state | thread: thread}
    {items, cut} = replay(state.history)
    event = {:harness_session, thread, cut}

    if items == [] do
      {events, state} = start_turn(state)
      {[event | events], state}
    else
      # The items are JSON already: the line is joined from them.
      send_line(state, [
        ~s({"id":#{@inject},"method":"thread/inject_items","params":{"threadId":),
        JSON.encode!(thread),
        ~s(,"items":[),
        Enum.intersperse(items, ","),
        "]}}"
      ])

      {[event], state}
    end
  end

  defp translate(%{"id" => @inject, "result" => _}, state), do: start_turn(state)

  defp translate(%{"id" => @turn, "result" => %{"turn" => %{"id" => turn}}}, state)
       when is_binary(turn),
       do: {[], %{state | turn: turn}}

  # The end of the turn, not this answer, ends an interrupt.
  defp translate(%{"id" => @interrupt}, state), do: {[], state}

  defp translate(%{"id" => id} = response, state) when is_map_key(@methods, id) do
    message = error_message(response) || "unexpected response"
    {[], finish(state, {:error, {:codex, @methods[id], HarnessIO.cap_error(message)}})}
  end

  # Only the notifications of this run's thread count: a sub-agent's
  # thread stays inside the harness.
  defp translate(%{"method" => method, "params" => %{"threadId" => thread} = params}, state)
       when thread == state.thread and is_binary(thread),
       do: notification(method, params, state)

  defp translate(_object, state), do: {[], state}

  defp notification("item/agentMessage/delta", %{"delta" => text, "itemId" => id}, state)
       when is_binary(text) and text != "" do
    {[{:text_delta, text}], %{state | streamed: MapSet.put(state.streamed, id)}}
  end

  defp notification(method, %{"delta" => text}, state)
       when method in ["item/reasoning/summaryTextDelta", "item/reasoning/textDelta"] and
              is_binary(text) and text != "",
       do: {[{:thinking_delta, text}], state}

  defp notification("item/started", %{"item" => %{"type" => type, "id" => id} = item}, state)
       when type in @tool_item_types and is_binary(id) do
    state = %{state | started: MapSet.put(state.started, id), calls: [id | state.calls]}
    {[tool_call(item)], state}
  end

  # A message whose text came with no delta gives it whole.
  defp notification(
         "item/completed",
         %{"item" => %{"type" => "agentMessage", "id" => id, "text" => text}},
         state
       )
       when is_binary(text) and text != "" do
    if MapSet.member?(state.streamed, id),
      do: {[], state},
      else: {[{:text_delta, text}], state}
  end

  # The first result of a message's calls closes it; the results of its
  # other calls follow. A tool item that completes with no start gets its
  # call first.
  defp notification("item/completed", %{"item" => %{"type" => type, "id" => id} = item}, state)
       when type in @tool_item_types and is_binary(id) do
    {calls, state} =
      if MapSet.member?(state.started, id),
        do: {[], state},
        else: {[tool_call(item)], %{state | calls: [id | state.calls]}}

    result = {:tool_result, id, tool_result(item)}

    if id in state.calls do
      close = {:close, state.calls, {:message_end, :tool_use, state.usage}}
      {calls ++ [close, result], %{state | calls: []}}
    else
      {[result], state}
    end
  end

  defp notification("thread/tokenUsage/updated", %{"tokenUsage" => %{"last" => usage}}, state)
       when is_map(usage),
       do: {[], %{state | usage: usage}}

  # One run starts one turn, so the thread's turn end is its end.
  defp notification("turn/completed", %{"turn" => %{} = result}, state),
    do: {[], finish(state, terminal(result, state))}

  defp notification(_method, _params, state), do: {[], state}

  # The input ends, so the program exits by itself once it has written its
  # thread, within the exit wait.
  defp finish(state, terminal) do
    Helyx.Watchdog.write(state.port, <<0>>)
    HarnessIO.arm_exit_wait(state, terminal)
  end

  defp terminal(%{"status" => "completed"}, state),
    do: {:done, %{stop_reason: :end_turn, usage: state.usage}}

  defp terminal(result, _state) do
    status = HarnessIO.cap_error(result["status"])
    {:error, {:codex, status, HarnessIO.cap_error(error_message(result))}}
  end

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(_map), do: nil

  defp tool_call(%{"type" => type, "id" => id} = item),
    do: {:tool_call, %Message.ToolCall{id: id, name: type, arguments: arguments(item)}}

  defp arguments(%{"type" => "commandExecution"} = item), do: Map.take(item, ["command", "cwd"])

  defp arguments(item),
    do:
      item
      |> Map.drop(["id", "type", "status"])
      |> Map.reject(fn {_key, value} -> value == nil end)

  # A command gives its output; any other tool item gives its fields as
  # JSON.
  defp tool_result(item) do
    text =
      case item do
        %{"type" => "commandExecution", "aggregatedOutput" => out} when is_binary(out) -> out
        %{"type" => "commandExecution"} -> ""
        _ -> JSON.encode!(Map.drop(item, ["id", "type"]))
      end

    failed? =
      item["status"] in ["failed", "declined"] or item["error"] != nil or
        (is_integer(item["exitCode"]) and item["exitCode"] != 0)

    {if(failed?, do: :error, else: :ok), Helyx.Text.truncate(text, :tail)}
  end

  # Input

  defp start_thread(state) do
    request(state, @start, thread_params(state))
    {[], state}
  end

  defp thread_params(state), do: Map.merge(@trust, %{model: state.model, cwd: state.cwd})

  defp start_turn(state) do
    input =
      for %Message{content: blocks} <- state.prompt,
          %Message.Text{text: text} <- blocks,
          text != "",
          do: %{type: "text", text: text}

    request(state, @turn, %{threadId: state.thread, input: input})
    {[], state}
  end

  defp request(state, id, params),
    do: send_line(state, %{id: id, method: @methods[id], params: params})

  defp send_line(state, %{} = map), do: send_line(state, JSON.encode!(map))
  defp send_line(state, line), do: Helyx.Watchdog.write(state.port, [line, "\n"])

  # One entry per message, with its Responses API items: an assistant
  # message gives a message item per text and a `function_call` per tool
  # call (thinking is not replayed), a user message a message item, and a
  # tool result a `function_call_output`. The replay may start at any
  # message but a tool result, so every kept result keeps its call.
  defp replay(history) do
    entries =
      for message <- history do
        items = items(message)
        {items != [] && items, 1, message.role != :tool_result}
      end

    {kept, cut} = HarnessIO.cap_replay(entries, length(history))
    {List.flatten(kept), cut}
  end

  defp items(%Message{role: :tool_result} = message) do
    [
      item(%{
        type: "function_call_output",
        call_id: call_id(message.tool_call_id),
        output: Message.text(message)
      })
    ]
  end

  defp items(%Message{role: role, content: blocks}) do
    for block <- blocks, item = block_item(role, block), do: item(item)
  end

  defp block_item(:user, %Message.Text{text: text}) when text != "",
    do: %{type: "message", role: "user", content: [%{type: "input_text", text: text}]}

  defp block_item(:assistant, %Message.Text{text: text}) when text != "",
    do: %{type: "message", role: "assistant", content: [%{type: "output_text", text: text}]}

  defp block_item(:assistant, %Message.ToolCall{} = call) do
    %{
      type: "function_call",
      call_id: call_id(call.id),
      name: tool_name(call.name),
      arguments: JSON.encode!(call.arguments)
    }
  end

  defp block_item(_role, _block), do: nil

  # Each item is encoded once, so the cap counts its bytes.
  defp item(map), do: JSON.encode!(map)

  # The model API takes a call id of at most 64 characters; a longer id,
  # or one with a character outside `[a-zA-Z0-9_-]`, becomes a digest, the
  # same for a call and its result.
  defp call_id(id) do
    if id =~ ~r/\A[a-zA-Z0-9_-]{1,64}\z/,
      do: id,
      else: "h_" <> binary_part(Base.encode16(:crypto.hash(:sha256, id), case: :lower), 0, 62)
  end

  # The model API takes a tool name of `[a-zA-Z0-9_-]` only; the cut at 64
  # is the function name limit of the Chat Completions API, not verified for
  # `thread/inject_items` (see the research note).
  defp tool_name(name) do
    case String.replace(name, ~r/[^a-zA-Z0-9_-]/u, "_") do
      "" -> "_"
      name -> binary_part(name, 0, min(byte_size(name), 64))
    end
  end
end
