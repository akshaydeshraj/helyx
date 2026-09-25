defmodule Helyx.HarnessIO do
  @moduledoc false
  # What the harness providers share (ADR 0005): the read of a program's
  # stdout as JSON lines under a line cap, the exit wait after a terminal,
  # the cut of program error text, the split of the prompt from the
  # history, and the byte cap of a replay. It is not a plugin. `state` is a
  # provider's run state with the fields `buffer` (iodata), `size`,
  # `terminal`, `deadline`, and `done?`.

  @line_max_bytes 16 * 1024 * 1024
  # The wait for the exit after a terminal while the port is open, so the
  # program ends by itself and finishes writing its own session.
  @exit_wait_ms 5_000
  # The longest program error text that goes into a terminal error.
  @error_max_bytes 2_000
  @replay_max_bytes 400_000

  def line_max_bytes, do: @line_max_bytes
  def replay_max_bytes, do: @replay_max_bytes

  # Runs `argv` under the watchdog with `input` and puts the port in the
  # state. What came before the marker is perl's own output: the program
  # runs only after the go-ahead. A program that did not start gives the
  # terminal error.
  def start(argv, cwd, input, state, opts \\ []) do
    case Helyx.Watchdog.start(argv, cwd, input, opts) do
      {:started, port, _pre, _nonce, _go} ->
        %{state | port: port}

      {:not_started, port, acc} ->
        arm_exit_wait(%{state | port: port}, {:error, {:not_started, cap_error(acc)}})

      {:no_marker, text} ->
        %{state | done?: true, terminal: {:error, {:not_started, cap_error(text)}}}
    end
  end

  # The `Stream.resource/3` end: the closed port ends the program.
  def stop(%{port: nil}), do: :ok
  def stop(%{port: port}), do: Helyx.Watchdog.close(port)

  # The `next` of a run that is done: the terminal once, then the halt.
  def drain(%{terminal: nil} = state), do: {:halt, state}
  def drain(%{terminal: terminal} = state), do: {[terminal], %{state | terminal: nil}}

  # Reads a chunk of stdout: `decode` gets each complete line that is a
  # JSON object, and the state; other lines (the watchdog's start line,
  # perl's own text) are skipped. Once the state has a terminal, output is
  # not read. Only the new chunk is searched for a newline, so a long line
  # costs one pass over its bytes. A line over the cap, with its newline in
  # this chunk or not, ends the stream with an error.
  def lines(_data, %{terminal: terminal} = state, _decode) when terminal != nil, do: {[], state}

  def lines(data, state, decode) do
    case :binary.split(data, "\n") do
      [part | _] when state.size + byte_size(part) > @line_max_bytes ->
        {[], %{state | done?: true, terminal: {:error, {:line_over_limit, @line_max_bytes}}}}

      [part] ->
        {[], %{state | buffer: [state.buffer, part], size: state.size + byte_size(part)}}

      [part, rest] ->
        line = IO.iodata_to_binary([state.buffer, part])
        state = %{state | buffer: [], size: 0}

        {events, state} =
          case JSON.decode(line) do
            {:ok, %{} = object} -> decode.(object, state)
            _ -> {[], state}
          end

        {more, state} = lines(rest, state, decode)
        {events ++ more, state}
    end
  end

  # Every terminal that waits for the exit sets its deadline here.
  def arm_exit_wait(state, terminal),
    do: %{
      state
      | terminal: terminal,
        deadline: System.monotonic_time(:millisecond) + @exit_wait_ms
    }

  # The receive timeout: none before a terminal, the rest of the exit wait
  # after it.
  def wait(%{deadline: nil}), do: :infinity
  def wait(%{deadline: deadline}), do: remaining(deadline)

  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # A value that is not text is empty.
  def cap_error(text) when not is_binary(text), do: ""
  def cap_error(text) when byte_size(text) <= @error_max_bytes, do: text
  # A character cut in half is dropped, so the text stays within the cap.
  def cap_error(text),
    do: text |> binary_part(0, @error_max_bytes) |> String.replace_invalid("")

  # The prompt is the user messages at the end of the transcript; the
  # history is the rest. Both keep their order.
  def split_prompt(messages) do
    {prompt, history} = messages |> Enum.reverse() |> Enum.split_while(&(&1.role == :user))
    {Enum.reverse(prompt), Enum.reverse(history)}
  end

  # Keeps the newest entries within the byte cap, then drops kept entries
  # up to the first one the replay may start at. An entry is {iodata or
  # false, messages, start?}. Returns the kept iodata and the number of
  # messages left out of `total`.
  def cap_replay(entries, total) do
    {kept, _bytes} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn {data, _n, _start?} = entry, {kept, bytes} ->
        bytes = bytes + if(data, do: IO.iodata_length(data), else: 0)

        if bytes > @replay_max_bytes,
          do: {:halt, {kept, bytes}},
          else: {:cont, {[entry | kept], bytes}}
      end)

    kept = Enum.drop_while(kept, fn {_data, _n, start?} -> not start? end)

    {for({data, _n, _start?} <- kept, data, do: data),
     total - Enum.sum(for {_, n, _} <- kept, do: n)}
  end
end
