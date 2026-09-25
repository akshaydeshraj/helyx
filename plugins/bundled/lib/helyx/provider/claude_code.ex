defmodule Helyx.Provider.ClaudeCode do
  @replay_max_bytes 400_000
  @line_max_bytes 16 * 1024 * 1024

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
  newest messages within #{@replay_max_bytes} bytes of lines, and it never
  starts at a tool result, so no result loses its call. The
  `{:harness_session, id, cut}` event of a fresh session gives its id and
  the number of messages left out.

  Assistant text and thinking stream as deltas. Tool calls and their
  results arrive whole, and a `message_end` closes each assistant message
  whose tool calls the program ran. A stdout line over #{@line_max_bytes}
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

  # The wait for the exit after a terminal while the port is open: the
  # `result` line, so the program ends by itself at the end of its input and
  # finishes writing its own session, or a program that did not start.
  @exit_wait_ms 5_000
  @lost "No conversation found with session ID"
  # The longest program error text that goes into the terminal error.
  @error_max_bytes 2_000

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
        {:ok, Stream.resource(fn -> start(run, resume) end, &next/1, &stop/1)}
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

    # What came before the marker is perl's own output: the program runs
    # only after the go-ahead.
    case Helyx.Watchdog.start(argv, run.cwd, IO.iodata_to_binary(input)) do
      {:started, port, _pre, _nonce, _go} ->
        %{state | port: port}

      {:not_started, port, acc} ->
        arm_exit_wait(%{state | port: port}, {:error, {:not_started, cap_error(acc)}})

      {:no_marker, text} ->
        %{state | done?: true, terminal: {:error, {:not_started, cap_error(text)}}}
    end
  end

  # `--model=` and `--resume=` keep a value that starts with a dash a value.
  defp flags(model, resume) do
    ~w(-p --output-format stream-json --verbose --include-partial-messages
       --input-format stream-json --permission-mode bypassPermissions) ++
      ["--model=" <> model] ++ if(resume, do: ["--resume=" <> resume], else: [])
  end

  defp stop(%{port: nil}), do: :ok
  defp stop(%{port: port}), do: Helyx.Watchdog.close(port)

  defp next(%{done?: true, terminal: nil} = state), do: {:halt, state}

  defp next(%{done?: true, terminal: terminal} = state),
    do: {[terminal], %{state | terminal: nil}}

  # Before the result the wait is the program's own loop, which an abort
  # ends; after it, one exit wait from the terminal, whatever the program
  # still writes.
  defp next(%{port: port} = state) do
    receive do
      {^port, {:data, data}} -> lines(data, state)
      {^port, {:exit_status, status}} -> exited(status, %{state | port: nil})
    after
      wait(state) -> exit_timeout(state)
    end
  end

  # Every terminal that waits for the exit sets its deadline here.
  defp arm_exit_wait(state, terminal),
    do: %{
      state
      | terminal: terminal,
        deadline: System.monotonic_time(:millisecond) + @exit_wait_ms
    }

  defp wait(%{deadline: nil}), do: :infinity
  defp wait(%{deadline: deadline}), do: max(deadline - System.monotonic_time(:millisecond), 0)

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

  # Only the new chunk is searched for a newline, so a long line costs one
  # pass over its bytes.
  defp lines(_data, %{terminal: terminal} = state) when terminal != nil, do: {[], state}

  defp lines(data, state) do
    case :binary.split(data, "\n") do
      # A line over the cap, with its newline in this chunk or not.
      [part | _] when state.size + byte_size(part) > @line_max_bytes ->
        {[], %{state | done?: true, terminal: {:error, {:line_over_limit, @line_max_bytes}}}}

      [part] ->
        {[], %{state | buffer: [state.buffer, part], size: state.size + byte_size(part)}}

      [part, rest] ->
        line = IO.iodata_to_binary([state.buffer, part])
        {events, state} = decode(line, %{state | buffer: [], size: 0})
        {more, state} = lines(rest, state)
        {events ++ more, state}
    end
  end

  # Lines that are not a JSON object (the watchdog's start line, perl's own
  # text) are skipped. Output after the result is not read (`lines/2`).
  defp decode(line, state) do
    case JSON.decode(line) do
      {:ok, %{} = object} -> translate(object, state)
      _ -> {[], state}
    end
  end

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
        {:tool_result, id, {status, result_text(block["content"])}}
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
    do: {[], arm_exit_wait(state, terminal(result, state))}

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
      subtype = if is_binary(result["subtype"]), do: cap_error(result["subtype"]), else: ""
      {:error, {:claude_code, subtype, cap_error(text)}}
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

  defp cap_error(text) when byte_size(text) <= @error_max_bytes, do: text
  # A character cut in half is dropped, so the text stays within the cap.
  defp cap_error(text), do: text |> binary_part(0, @error_max_bytes) |> String.replace_invalid("")

  # Input

  # The prompt is the user messages at the end of the transcript. A resumed
  # harness session has the rest; a fresh one gets the rest first.
  defp input(messages, resume) do
    {prompt, history} = messages |> Enum.reverse() |> Enum.split_while(&(&1.role == :user))
    content = Enum.flat_map(Enum.reverse(prompt), &user_content/1)
    prompt_line = line(%{type: "user", message: %{role: "user", content: content}})

    if resume do
      {prompt_line, 0}
    else
      {lines, cut} = replay(Enum.reverse(history))
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

    cap_replay(entries, length(history))
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

  # Keeps the newest entries within the byte cap, then drops kept entries
  # up to the first one the replay may start at. Returns the lines and the
  # number of messages left out.
  defp cap_replay(entries, total) do
    {kept, _bytes} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn {line, _n, _start?} = entry, {kept, bytes} ->
        bytes = bytes + if(line, do: IO.iodata_length(line), else: 0)

        if bytes > @replay_max_bytes,
          do: {:halt, {kept, bytes}},
          else: {:cont, {[entry | kept], bytes}}
      end)

    kept = Enum.drop_while(kept, fn {_line, _n, start?} -> not start? end)

    {for({line, _n, _start?} <- kept, line, do: line),
     total - Enum.sum(for {_, n, _} <- kept, do: n)}
  end

  # The Messages API takes tool ids of `[a-zA-Z0-9_-]` only; another
  # provider's id can have other characters.
  defp tool_id(id), do: String.replace(id, ~r/[^a-zA-Z0-9_-]/, "_")

  defp line(map), do: [JSON.encode!(map), "\n"]
end
