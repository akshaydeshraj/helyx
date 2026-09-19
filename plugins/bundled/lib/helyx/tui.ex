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
      * Alt+Enter sends it as a follow-up
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

    @impl true
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
          sent =
            if "alt" in key.modifiers do
              Session.follow_up(state.session, text)
            else
              Session.steer(state.session, text)
            end

          # A rejected message (full queue, bad UTF-8) stays in the composer.
          case sent do
            :ok -> ExRatatui.text_input_set_value(state.input, "")
            {:error, _reason} -> :ok
          end

          {:noreply, state}
      end
    end

    # Everything else goes to the input widget, which inserts printable
    # characters and handles its own editing keys.
    def handle_event(%Key{} = key, state) do
      if key.kind in ["press", "repeat"] and key.modifiers -- ["shift"] == [] do
        ExRatatui.text_input_handle_key(state.input, key.code)
      end

      {:noreply, state}
    end

    def handle_event(%Paste{content: content}, state) do
      ExRatatui.text_input_insert_str(state.input, content)
      {:noreply, state}
    end

    def handle_event(_event, state), do: {:noreply, state}

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

    # One styled Line per screen row: split on newlines, then chunk to width.
    # ponytail: width counts graphemes, wide CJK glyphs overflow by one column (#40)
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

    defp wrap(line, width) do
      case line |> String.graphemes() |> Enum.chunk_every(max(width, 1)) do
        [] -> [""]
        chunks -> Enum.map(chunks, &Enum.join/1)
      end
    end

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

      %Paragraph{
        text: %Line{
          spans: [
            %Span{
              content: " #{vm.model} · #{state} · queued #{steers}+#{follow_ups} ",
              style: @bold
            },
            %Span{
              content: " Enter steer · Alt+Enter follow-up · Esc abort · Ctrl+C quit",
              style: @dim
            }
          ]
        }
      }
    end
  end
end
