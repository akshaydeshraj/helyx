defmodule Helyx.Provider.ClaudeCode do
  alias Helyx.HarnessIO

  @moduledoc """
  A harness provider that drives the unmodified Claude Code program,
  `claude -p`, with stream-json input and output (ADR 0002). The model ref
  is `claude-code/<model>`, where `<model>` is what `claude --model` takes:
  an alias such as `haiku`, `sonnet`, or `opus`, or a full model name.

  One harness turn is one run of `claude` from `PATH` in the session's
  working directory, in its own process group under the watchdog of
  `Helyx.Watchdog`. The session runs the stream as a Task of the hands; the
  run holds its groups with `Helyx.Tool.hold/1`, and the hands release them
  through `release/3`, so an abort returns only when the program is gone
  (ADR 0004). The program runs with `--permission-mode bypassPermissions`,
  the same trust as the bash tool, and uses its own tools; Helyx tools are
  not offered. Its stderr is dropped: the `result` line carries the errors.

  With the `:harness_session_id` option the run resumes that harness
  session and sends only the new prompt: the user messages at the end of
  the transcript. Without it, or when the program no longer has that
  session, the run starts a fresh harness session and first sends the rest
  of the transcript as lines that start no model call. The replay keeps the
  newest messages within #{HarnessIO.replay_max_bytes()} bytes of lines, and it never
  starts at a tool result, so no result loses its call. The
  `{:harness_session, id, cut}` event of a fresh session gives its id and
  the number of messages left out.

  Assistant text and thinking stream as deltas. Tool calls and their
  results arrive whole, and a `message_end` closes each assistant message
  whose tool calls the program ran. A stdout line over #{HarnessIO.line_max_bytes()}
  bytes ends the stream with an error. The protocol facts are in
  `docs/research/claude-code-stream-json.md`.
  """

  @behaviour Helyx.Provider

  alias Helyx.Message

  defmodule Run do
    @moduledoc false
    # What every run of one stream call shares: a lost session's fresh run
    # starts from it again.
    @enforce_keys [:exe, :model, :cwd, :messages]
    defstruct [:exe, :model, :cwd, :messages]
  end

  defmodule State do
    @moduledoc false
    # One run of the program (see `start/2`).
    @enforce_keys [:run, :resume, :cut]
    defstruct [
      :run,
      :resume,
      :cut,
      :port,
      :terminal,
      # The monotonic time in ms when the exit wait ends, set with `terminal`.
      :deadline,
      buffer: [],
      size: 0,
      usage: %{},
      init?: false,
      open?: false,
      calls?: false,
      done?: false
    ]
  end

  @lost "No conversation found with session ID"

  @impl true
  def id, do: "claude-code"

  @impl true
  def kind, do: :harness

  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog

  @impl true
  def stream(model, %Helyx.Context{messages: messages}, opts) do
    case System.find_executable("claude") do
      nil ->
        {:error, "claude not found on PATH"}

      exe ->
        run = %Run{exe: exe, model: model, cwd: Keyword.fetch!(opts, :cwd), messages: messages}
        resume = opts[:harness_session_id]
        {:ok, Stream.resource(fn -> start(run, resume) end, &next/1, &HarnessIO.stop/1)}
    end
  end

  # One run of the program. `resume` is the harness session id it resumes,
  # or nil for a fresh one. `open?` is true while the current assistant
  # message has content that no `message_end` closed, and `calls?` when that
  # content has a tool call. `terminal` holds the result until the exit.
  defp start(run, resume) do
    {input, cut} = input(run.messages, resume)
    argv = ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), run.exe | flags(run.model, resume)]

    state = %State{run: run, resume: resume, cut: cut}

    HarnessIO.start(argv, run.cwd, IO.iodata_to_binary(input), state)
  end

  # `--model=` and `--resume=` keep a value that starts with a dash a value.
  defp flags(model, resume) do
    ~w(-p --output-format stream-json --verbose --include-partial-messages
       --input-format stream-json --permission-mode bypassPermissions) ++
      ["--model=" <> model] ++ if(resume, do: ["--resume=" <> resume], else: [])
  end

  defp next(%{done?: true} = state), do: HarnessIO.drain(state)

  # Before the result the wait is the program's own loop, which an abort
  # ends; after it, one exit wait from the terminal, whatever the program
  # still writes.
  defp next(%{port: port} = state) do
    if HarnessIO.overdue?(state), do: exit_timeout(state), else: receive_next(port, state)
  end

  defp receive_next(port, state) do
    receive do
      {^port, {:data, data}} -> HarnessIO.lines(data, state, &translate/2)
      {^port, {:exit_status, status}} -> exited(status, %{state | port: nil})
    after
      HarnessIO.wait(state) -> exit_timeout(state)
    end
  end

  # The program no longer has the session: the run starts again with a
  # fresh one. Nothing ran in the lost run (see the research note).
  defp exited(_status, %{terminal: :lost} = state), do: {[], start(state.run, nil)}

  defp exited(_status, %{terminal: terminal} = state) when terminal != nil,
    do: {[], %{state | done?: true}}

  defp exited(status, state),
    do: {[], %{state | done?: true, terminal: {:error, {:claude_code_exit, status}}}}

  defp exit_timeout(%{terminal: :lost} = state) do
    Helyx.Watchdog.close(state.port)
    {[], start(state.run, nil)}
  end

  defp exit_timeout(state), do: {[], %{state | done?: true}}

  # A sub-agent's own messages stay inside the harness.
  defp translate(%{"parent_tool_use_id" => parent}, state) when parent != nil, do: {[], state}

  # Each query of the run repeats the init line.
  defp translate(
         %{"type" => "system", "subtype" => "init", "session_id" => id},
         %{init?: false} = state
       )
       when is_binary(id) do
    events = if state.resume, do: [], else: [{:harness_session, id, state.cut}]
    {events, %{state | init?: true}}
  end

  defp translate(
         %{
           "type" => "stream_event",
           "event" => %{"type" => "content_block_delta", "delta" => delta}
         },
         state
       ) do
    case delta do
      %{"type" => "text_delta", "text" => text} when is_binary(text) and text != "" ->
        {[{:text_delta, text}], %{state | open?: true}}

      %{"type" => "thinking_delta", "thinking" => text} when is_binary(text) and text != "" ->
        {[{:thinking_delta, text}], %{state | open?: true}}

      _ ->
        {[], state}
    end
  end

  # The text of an assistant line already came as deltas; only its tool
  # calls and its usage are new.
  defp translate(%{"type" => "assistant", "message" => %{"content" => blocks} = message}, state)
       when is_list(blocks) do
    calls =
      for %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{} = input} <- blocks,
          do: {:tool_call, %Message.ToolCall{id: id, name: name, arguments: input}}

    usage = if is_map(message["usage"]), do: message["usage"], else: state.usage
    some? = calls != []
    {calls, %{state | open?: state.open? or some?, calls?: state.calls? or some?, usage: usage}}
  end

  defp translate(%{"type" => "user", "message" => %{"content" => blocks}}, state)
       when is_list(blocks) do
    results =
      for %{"type" => "tool_result", "tool_use_id" => id} = block <- blocks do
        status = if block["is_error"] == true, do: :error, else: :ok
        {:tool_result, id, {status, Helyx.Text.truncate(result_text(block["content"]), :tail)}}
      end

    case results do
      [] -> {[], state}
      _ -> {close_message(state) ++ results, %{state | open?: false, calls?: false}}
    end
  end

  # Each replayed line gets an empty result and runs no model call.
  defp translate(%{"type" => "result", "subtype" => "success", "num_turns" => 0}, state),
    do: {[], state}

  defp translate(%{"type" => "result"} = result, state),
    do: {[], HarnessIO.arm_exit_wait(state, terminal(result, state))}

  defp translate(_object, state), do: {[], state}

  defp close_message(%{open?: false}), do: []

  defp close_message(state),
    do: [{:message_end, if(state.calls?, do: :tool_use, else: :end_turn), state.usage}]

  defp terminal(%{"is_error" => false, "subtype" => "success"} = result, state) do
    stop = if result["stop_reason"] == "max_tokens", do: :max_tokens, else: :end_turn
    {:done, %{stop_reason: stop, usage: state.usage}}
  end

  defp terminal(result, state) do
    errors =
      if is_list(result["errors"]), do: Enum.filter(result["errors"], &is_binary/1), else: []

    if state.resume && !state.init? && Enum.any?(errors, &String.starts_with?(&1, @lost)) do
      :lost
    else
      text = Enum.join(errors, "; ")
      text = if text == "" and is_binary(result["result"]), do: result["result"], else: text

      subtype =
        HarnessIO.cap_error(result["subtype"])

      {:error, {:claude_code, subtype, HarnessIO.cap_error(text)}}
    end
  end

  defp result_text(text) when is_binary(text), do: text

  defp result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => type} when is_binary(type) -> "[#{type}]"
      _ -> ""
    end)
  end

  defp result_text(_content), do: ""

  # Input

  # The prompt is the user messages at the end of the transcript. A resumed
  # harness session has the rest; a fresh one gets the rest first.
  defp input(messages, resume) do
    {prompt, history} = HarnessIO.split_prompt(messages)
    content = Enum.flat_map(prompt, &user_content/1)
    prompt_line = line(%{type: "user", message: %{role: "user", content: content}})

    if resume do
      {prompt_line, 0}
    else
      {lines, cut} = replay(history)
      {[lines, prompt_line], cut}
    end
  end

  # One line per assistant message, and one `shouldQuery: false` user line
  # for each run of user messages and tool results between them. An entry
  # is {line or false, messages, start?}: the replay may start at an entry
  # whose line has no tool result, because the call of every kept result is
  # then kept too.
  defp replay(history) do
    entries =
      history
      |> Enum.chunk_by(&(&1.role == :assistant))
      |> Enum.flat_map(fn
        [%Message{role: :assistant} | _] = messages -> Enum.map(messages, &assistant_entry/1)
        messages -> [user_entry(messages)]
      end)

    HarnessIO.cap_replay(entries, length(history))
  end

  defp assistant_entry(%Message{content: blocks}) do
    content =
      for block <- blocks, json = assistant_block(block), do: json

    {content != [] && line(%{type: "assistant", message: %{role: "assistant", content: content}}),
     1, true}
  end

  # Thinking is not replayed: its signature belongs to the model that made it.
  defp assistant_block(%Message.Text{text: text}) when text != "", do: %{type: "text", text: text}

  defp assistant_block(%Message.ToolCall{} = call),
    do: %{type: "tool_use", id: tool_id(call.id), name: call.name, input: call.arguments}

  defp assistant_block(_block), do: nil

  defp user_entry(messages) do
    content = Enum.flat_map(messages, &user_content/1)
    start? = not Enum.any?(messages, &(&1.role == :tool_result))
    message = %{role: "user", content: content}

    {content != [] && line(%{type: "user", shouldQuery: false, message: message}),
     length(messages), start?}
  end

  defp user_content(%Message{role: :tool_result} = message) do
    [
      %{
        type: "tool_result",
        tool_use_id: tool_id(message.tool_call_id),
        content: Message.text(message),
        is_error: message.is_error
      }
    ]
  end

  defp user_content(%Message{content: blocks}) do
    for %Message.Text{text: text} <- blocks, text != "", do: %{type: "text", text: text}
  end

  # The Messages API takes tool ids of `[a-zA-Z0-9_-]` only; another
  # provider's id can have other characters.
  defp tool_id(id), do: String.replace(id, ~r/[^a-zA-Z0-9_-]/, "_")

  defp line(map), do: [JSON.encode!(map), "\n"]
end
