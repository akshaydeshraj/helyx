# ex_ratatui is an optional dependency (ADR 0005): without it Helyx.TUI does
# not exist, and a product that wants the TUI adds ex_ratatui itself.
defmodule Helyx.TUI.Available do
  @moduledoc false
  # A product can add or remove ex_ratatui after its first build, and Mix does
  # not see that as a reason to compile this file again. Two parts make it do
  # so, and both are necessary (measurements in ADR 0005). This module always
  # exists and lives in this file, because Mix reaches a stale source only
  # through a module the source defines. `__mix_recompile__?/0` tells Mix on
  # every compile whether the answer changed.

  @available Code.ensure_loaded?(ExRatatui.App)

  @spec available?() :: boolean()
  def available?, do: @available

  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Code.ensure_loaded?(ExRatatui.App) != @available
end

if Helyx.TUI.Available.available?() do
  defmodule Helyx.TUI do
    @moduledoc """
    The terminal interface, an `ExRatatui.App` in the alternate screen.

    The TUI subscribes to one session and renders from `Helyx.TUI.ViewModel`,
    a pure fold over the session's events. It holds no session state of its
    own. Keys:

      * typing fills the composer (`ExRatatui.Widgets.TextInput`: cursor
        movement, Home/End, Delete, Backspace)
      * Enter sends the composer as a steer (a prompt when no turn runs)
      * Alt+Enter sends it as a follow-up. A rejected send (full queue, text
        that is not valid UTF-8) stays in the composer, and the status bar
        shows the reason until the next key press or paste
      * `/model provider/model` in the composer switches the model; the next
        turn uses it. A rejected ref shows a notice and stays in the composer
      * Escape aborts the running turn
      * Ctrl+C quits and restores the terminal

    Start it with `run/1`, which blocks until the user quits:

        Helyx.TUI.run(session: session, model: "opencode-go/kimi-k2")
    """

    use ExRatatui.App

    alias ExRatatui.Event.{Key, Paste}
    alias ExRatatui.Layout
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.{Block, Paragraph, TextInput}
    alias Helyx.{Message, Session}
    alias Helyx.TUI.ViewModel

    @dim %Style{modifiers: [:dim]}
    @bold %Style{modifiers: [:bold]}
    @tool %Style{fg: :cyan}
    @bad %Style{fg: :red}

    # East Asian Wide and Fullwidth blocks, the emoji blocks, and other ranges
    # that ExRatatui draws as two columns.
    @wide_ranges [
      0x1100..0x115F,
      0x2329..0x232A,
      0x2630..0x2637,
      0x268A..0x268F,
      0x2E80..0x303E,
      0x3041..0xA4CF,
      0xA960..0xA97F,
      0xAC00..0xD7A3,
      0xF900..0xFAFF,
      0xFE10..0xFE19,
      0xFE30..0xFE6F,
      0xFF01..0xFF60,
      0xFFE0..0xFFE6,
      0x16FE0..0x18DFF,
      0x1AFF0..0x1B2FF,
      0x1D300..0x1D37F,
      0x1F18E..0x1F19A,
      0x1F1E6..0x1F2FF,
      0x1F300..0x1F64F,
      0x1F680..0x1F6FF,
      0x1F7E0..0x1F7F0,
      0x1F900..0x1F9FF,
      0x1FA70..0x1FAFF,
      0x20000..0x3FFFD
    ]

    # The emoji outside the emoji blocks that are two columns with no selector.
    @wide_symbols Enum.concat([
                    [0x231A, 0x231B, 0x23F0, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615],
                    [0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4],
                    [0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA],
                    [0x26FD, 0x2705, 0x270A, 0x270B, 0x2728, 0x274C, 0x274E, 0x2757],
                    [0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55, 0x1F004, 0x1F0CF],
                    0x23E9..0x23EC,
                    0x2648..0x2653,
                    0x2753..0x2755,
                    0x2795..0x2797
                  ])

    @doc "Starts the TUI for a session and blocks until the user quits."
    @spec run(keyword()) :: :ok | {:error, term()}
    def run(opts) do
      # A failed init (dead session, no terminal) exits the linked caller
      # before start_link can return the error. Trapping for just the start
      # window turns that into the {:error, reason} return; the flag is
      # restored before blocking, so the caller's other links keep their kill
      # semantics while the TUI runs.
      trap = Process.flag(:trap_exit, true)

      case start_link(opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          # Unlinked, an abnormal exit reaches the receive as a DOWN instead
          # of killing the caller through the link before it can return the
          # error. Unlink before restoring the flag, so no kill window opens.
          Process.unlink(pid)
          Process.flag(:trap_exit, trap)

          receive do
            {:DOWN, ^ref, :process, ^pid, :normal} -> flush_exit(pid, :ok)
            {:DOWN, ^ref, :process, ^pid, reason} -> flush_exit(pid, {:error, reason})
          end

        {:error, reason} ->
          # proc_lib unlinks and flushes the dead child's exit signal before
          # start_link returns an error, so there is nothing to drain here.
          Process.flag(:trap_exit, trap)
          {:error, reason}
      end
    end

    # A crash inside the trap window queues an {:EXIT, pid, _} message the
    # restored flag can no longer prevent; drop it with the result.
    defp flush_exit(pid, result) do
      receive do
        {:EXIT, ^pid, _reason} -> result
      after
        0 -> result
      end
    end

    @impl true
    def mount(opts) do
      session = Keyword.fetch!(opts, :session)
      :ok = Session.subscribe(session)

      # A monitor surfaces a dying session through run/1. A session that is
      # already gone has nothing to monitor; exit now rather than hang idle.
      case Session.pid(session) do
        nil -> exit({:session_down, :noproc})
        pid -> Process.monitor(pid)
      end

      {:ok,
       %{
         session: session,
         vm: ViewModel.new(Keyword.fetch!(opts, :model)),
         input: ExRatatui.text_input_new()
       }}
    end

    @impl true
    def handle_info({:helyx_event, event}, state) do
      {:noreply, %{state | vm: ViewModel.apply(state.vm, event)}}
    end

    # A dead session leaves nothing to render; exiting surfaces the reason
    # through run/1 instead of a noproc crash on the next keypress.
    def handle_info({:DOWN, _ref, :process, _pid, reason}, _state) do
      exit({:session_down, reason})
    end

    def handle_info(_msg, state), do: {:noreply, state}

    # The next key press or paste clears the reason of the last reject, then
    # runs as usual, so it can set a new reason. The release and the repeat of
    # a key are not a new press: those of the rejected Enter keep the reason.
    @impl true
    def handle_event(%Key{kind: "press"} = key, %{vm: %ViewModel{reason: reason}} = state)
        when is_binary(reason),
        do: handle_event(key, %{state | vm: ViewModel.clear_reason(state.vm)})

    def handle_event(%Paste{} = paste, %{vm: %ViewModel{reason: reason}} = state)
        when is_binary(reason),
        do: handle_event(paste, %{state | vm: ViewModel.clear_reason(state.vm)})

    def handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state), do: {:stop, state}

    def handle_event(%Key{code: "esc", kind: "press"}, state) do
      # Abort waits for the hands to kill every OS process; a Task keeps that
      # wait off the render loop.
      session = state.session
      Task.start(fn -> Session.abort(session) end)
      {:noreply, state}
    end

    def handle_event(%Key{code: "enter", kind: "press"} = key, state) do
      case ExRatatui.text_input_get_value(state.input) do
        "" ->
          {:noreply, state}

        text ->
          case command(text) do
            {:model, ref} -> {:noreply, switch_model(ref, state)}
            :message -> {:noreply, send_message(text, key, state)}
          end
      end
    end

    # Everything else goes to the input widget, which inserts printable
    # characters and handles its own editing keys.
    def handle_event(%Key{} = key, state) do
      if key.kind in ["press", "repeat"] and key.modifiers -- ["shift"] == [] do
        {:noreply, edit(state, key.code, &ExRatatui.text_input_handle_key/2)}
      else
        {:noreply, state}
      end
    end

    def handle_event(%Paste{content: content}, state),
      do: {:noreply, edit(state, content, &ExRatatui.text_input_insert_str/2)}

    def handle_event(_event, state), do: {:noreply, state}

    # The only path by which event text reaches the widget. The widget raises
    # `ArgumentError` on text that is not valid UTF-8, and a raise in a
    # callback kills the TUI process. Reject, do not repair: a silent
    # replacement would send text the user did not type.
    defp edit(state, text, fun) do
      if is_binary(text) and String.valid?(text) do
        fun.(state.input, text)
        state
      else
        %{state | vm: ViewModel.reject(state.vm, "input rejected: not valid UTF-8")}
      end
    end

    # `/model` is the only command. The rule is on bytes, not on looks; the
    # feature doc's bounds table holds the rule and its limit. The input
    # widget drops control characters from a paste, so `/model<tab>a/b`
    # arrives as `/modela/b`: no separator after the word, so the usage
    # notice. The ref goes to `Helyx.ModelRef` unsplit, which owns its bounds.
    # The widget holds only valid UTF-8; the `u` flag raises on anything else.
    defp command(text) do
      case Regex.run(~r/\A[\s\p{C}]*\/model([\s\p{C}]*)/u, text, return: :index) do
        nil -> :message
        [{0, head}, {_, 0}] when head < byte_size(text) -> {:model, ""}
        [{0, head}, _] -> {:model, String.trim(binary_part(text, head, byte_size(text) - head))}
      end
    end

    defp send_message(text, key, state) do
      sent =
        if "alt" in key.modifiers do
          Session.follow_up(state.session, text)
        else
          Session.steer(state.session, text)
        end

      # A rejected message stays in the composer, and the status bar says why.
      case sent do
        :ok ->
          ExRatatui.text_input_set_value(state.input, "")
          state

        {:error, reason} ->
          %{state | vm: ViewModel.reject(state.vm, send_error(reason))}
      end
    end

    # `edit/3` lets only valid UTF-8 into the composer, so `:invalid_utf8`
    # has no known source; the clause keeps the match total over the spec.
    defp send_error(:queue_full), do: "not sent: the queue is full"
    defp send_error(:invalid_utf8), do: "not sent: not valid UTF-8"

    defp switch_model("", state),
      do: %{state | vm: ViewModel.notice(state.vm, "usage: /model provider/model")}

    # The status bar follows the session's `:model_change` event, not this
    # call. A rejected ref stays in the composer, under a notice.
    defp switch_model(ref, state) do
      case Session.set_model(state.session, ref) do
        :ok ->
          ExRatatui.text_input_set_value(state.input, "")
          state

        {:error, reason} ->
          %{state | vm: ViewModel.notice(state.vm, model_error(reason))}
      end
    end

    # A notice shows at most the provider id, which the ref bounds cap.
    defp model_error({:unknown_provider, id}), do: "unknown provider: #{id}"
    defp model_error({:ambiguous_provider, id}), do: "two providers have the id #{id}"

    defp model_error({:invalid_model_ref, _ref}), do: "invalid model ref: use provider/model"

    @impl true
    def render(state, frame) do
      area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

      [transcript, composer, status] =
        Layout.split(area, :vertical, [{:min, 0}, {:length, 3}, {:length, 1}])

      [
        {transcript_widget(state.vm, transcript), transcript},
        {composer_widget(state.input), composer},
        {status_widget(state.vm), status}
      ]
    end

    # Transcript

    # The newest lines win: everything is rendered to width-bounded lines and
    # the last rows that fit are shown.
    # ponytail: no scrollback, add a scroll offset when reading history matters (#39)
    defp transcript_widget(vm, %Rect{width: width, height: height}) do
      # Every cell yields at least one line, so the last `height` cells
      # always fill the screen; older ones would be wrapped and dropped.
      vm = %{vm | cells: Enum.take(vm.cells, -height)}
      %Paragraph{text: Enum.take(transcript_lines(vm, width), -height)}
    end

    @doc false
    # Public for tests: the transcript as width-bounded `Line` structs.
    def transcript_lines(%ViewModel{} = vm, width) do
      streaming =
        if vm.streaming,
          do: [%Message{role: :assistant, content: Enum.reverse(vm.streaming)}],
          else: []

      Enum.flat_map(vm.cells ++ streaming, &(cell_lines(&1, width) ++ [%Line{}]))
    end

    defp cell_lines(%Message{role: :user} = message, width) do
      styled_lines("› " <> Message.text(message), width, @bold)
    end

    defp cell_lines(%Message{role: :assistant} = message, width) do
      block_lines(message.content, width)
    end

    defp cell_lines({:tool, call, result}, width) do
      call_line = styled_lines("⚙ #{call.name} #{compact_arguments(call)}", width, @tool)
      call_line ++ result_lines(result, width)
    end

    defp cell_lines({:notice, text}, width), do: styled_lines("✕ #{text}", width, @bad)

    defp block_lines(blocks, width) do
      Enum.flat_map(blocks, fn
        %Message.Text{text: text} -> styled_lines(text, width, %Style{})
        %Message.Thinking{thinking: text} -> styled_lines(text, width, @dim)
        %Message.ToolCall{} -> []
      end)
    end

    defp result_lines(nil, width), do: styled_lines("… running", width, @dim)

    # Long tool output would drown the transcript; four lines tell the story.
    defp result_lines(%Message{} = result, width) do
      style = if result.is_error, do: @bad, else: @dim
      lines = result |> Message.text() |> String.trim_trailing("\n") |> String.split("\n")

      shown = Enum.flat_map(Enum.take(lines, 4), &styled_lines("  " <> &1, width, style))

      case length(lines) - 4 do
        hidden when hidden > 0 ->
          plural = if hidden == 1, do: "line", else: "lines"
          shown ++ styled_lines("  … #{hidden} more #{plural}", width, @dim)

        _ ->
          shown
      end
    end

    defp compact_arguments(%Message.ToolCall{arguments: arguments}) do
      arguments
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
      |> String.replace("\n", "␤")
    end

    # One styled Line per screen row: split on newlines, then wrap to width.
    defp styled_lines(text, width, style) do
      for source_line <- text |> sanitize() |> String.split("\n"),
          chunk <- wrap(source_line, width) do
        %Line{spans: [%Span{content: chunk, style: style}]}
      end
    end

    # Model text and tool output reach the terminal raw through span content,
    # so an ESC, OSC, or CSI sequence in a file could retitle the terminal or
    # move the cursor. Tabs become spaces; other control characters drop.
    defp sanitize(text) do
      text
      # Bash output is arbitrary bytes; the /u regex raises on invalid UTF-8,
      # and a raw 0x9B byte is a one-byte CSI.
      |> String.replace_invalid("")
      |> String.replace("\t", "  ")
      |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]/u, "")
    end

    # The wrap is one pure function from a line and a width to its rows. No
    # row is wider than `width` columns, with one exception: a glyph wider than
    # the whole width gets a row of its own, so that the wrap always ends.
    # Fast path: no code point has more columns than bytes, so a line of
    # `width` bytes or less is one row. This also covers the empty line.
    defp wrap(line, width) when byte_size(line) <= width, do: [line]

    defp wrap(line, width) do
      width = max(width, 1)

      {rows, row, _used} =
        line
        |> String.graphemes()
        |> Enum.reduce({[], [], 0}, fn grapheme, {rows, row, used} ->
          needs = columns(grapheme)

          if used + needs > width and row != [],
            do: {[row | rows], [grapheme], needs},
            else: {rows, [grapheme | row], used + needs}
        end)

      Enum.map(Enum.reverse([row | rows]), &(&1 |> Enum.reverse() |> Enum.join()))
    end

    # ponytail: a short width rule, not the Unicode tables (ticket #90).
    # ExRatatui has no width function in Elixir, and OTP has no
    # `:string.width/1`. The rule must never count less than ExRatatui draws,
    # because ExRatatui cuts a row at the edge. So it has no rule for an emoji
    # sequence: ExRatatui draws an emoji with a skin tone, a joiner sequence, or
    # a flag as two columns, and this rule counts each emoji in it. Such a row
    # is shorter than it could be. Replace this with a width function of
    # ExRatatui when it has one.
    #
    # Fast path: the clause below gives the same result for ASCII.
    defp columns(<<byte>>) when byte < 0x80, do: 1
    defp columns(grapheme), do: sum_columns(grapheme, 0)

    # ExRatatui adds the code points of a grapheme: a Devanagari cluster can be
    # four columns. The emoji selector U+FE0F makes the code point before it
    # two columns.
    defp sum_columns(<<code::utf8, 0xFE0F::utf8, rest::binary>>, sum),
      do: sum_columns(rest, sum + max(code_point_columns(code), 2))

    defp sum_columns(<<code::utf8, rest::binary>>, sum),
      do: sum_columns(rest, sum + code_point_columns(code))

    defp sum_columns(<<>>, sum), do: sum

    # Combining marks, zero-width spaces, joiners and direction marks, variation
    # selectors, emoji tags, and the Hangul vowels and finals that join the
    # syllable before them. Marks of other scripts count as one column.
    defp code_point_columns(code)
         when code in 0x0300..0x036F or code in 0x1160..0x11FF or code in 0x200B..0x200F or
                code in 0x20D0..0x20F0 or code in 0xFE00..0xFE0F or code in 0xFE20..0xFE2F or
                code in 0xE0000..0xE0FFF,
         do: 0

    # Two Khmer code points that ExRatatui draws as the letters they stand for.
    defp code_point_columns(0x17A4), do: 2
    defp code_point_columns(0x17D8), do: 3
    defp code_point_columns(code), do: if(wide?(code), do: 2, else: 1)

    # East Asian Wide and Fullwidth, and the emoji that are wide by default.
    # No code point below U+1100 is wide.
    defp wide?(code) when code < 0x1100, do: false

    # One guard clause for each range: `in` on a range that is not a literal
    # goes through a protocol for each code point.
    for first..last//_ <- @wide_ranges do
      defp wide?(code) when code in unquote(first)..unquote(last), do: true
    end

    defp wide?(code), do: code in @wide_symbols

    # Composer and status

    defp composer_widget(input) do
      %TextInput{
        state: input,
        cursor_style: %Style{modifiers: [:reversed]},
        block: %Block{borders: [:all], title: "prompt"}
      }
    end

    defp status_widget(vm) do
      state = if vm.running?, do: "working", else: "idle"
      %{steers: steers, follow_ups: follow_ups} = vm.queue
      # The reason is a fixed text of this module, never input. It comes
      # first: the line does not wrap, and a model ref can be 256 bytes.
      reason = if vm.reason, do: [%Span{content: " ✕ #{vm.reason} ", style: @bad}], else: []

      model = %Span{
        content: " #{vm.model} · #{state} · queued #{steers}+#{follow_ups} ",
        style: @bold
      }

      keys = %Span{
        content: " Enter steer · Alt+Enter follow-up · Esc abort · Ctrl+C quit",
        style: @dim
      }

      %Paragraph{text: %Line{spans: reason ++ [model, keys]}}
    end
  end
end
