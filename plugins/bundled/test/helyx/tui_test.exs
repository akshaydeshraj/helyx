defmodule Helyx.TUI.Test.Tool.Slow do
  @moduledoc false
  # Sleeps, so a test can hold a turn open while it fills the queues.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def description, do: "Sleeps, then echoes."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(%{"ms" => ms, "text" => text}, _cwd) do
    Process.sleep(ms)
    {:ok, text}
  end
end

defmodule Helyx.TUI.Test.Provider.Other do
  @moduledoc false
  # A second provider module, so a test can switch away from Fake and back.
  @behaviour Helyx.Provider

  @impl true
  def id, do: "other"

  @impl true
  def stream(_model, _context, _opts) do
    {:ok, [{:text_delta, "from other"}, {:done, %{stop_reason: :end_turn, usage: %{}}}]}
  end
end

defmodule Helyx.TUITest do
  # The app callbacks, driven directly: mount subscribes the caller, key
  # events edit and send the composer, session events fold into the view
  # model. The fold itself is tested in view_model_test.exs.
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Helyx.{Event, Session}
  alias Helyx.Provider.Fake
  alias Helyx.TUI
  alias Helyx.TUI.ViewModel

  setup do
    core = :"tui_core_#{System.unique_integer([:positive])}"
    plugins = [Fake, Helyx.TUI.Test.Provider.Other, Helyx.TUI.Test.Tool.Slow]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp mounted(core, model, responses) do
    :ok = Fake.script(core, model, responses)
    {:ok, session} = Session.start(core, model: "fake/#{model}")
    {:ok, state} = TUI.mount(session: session, model: "fake/#{model}")
    state
  end

  defp press(state, code, modifiers \\ []) do
    {:noreply, state} =
      TUI.handle_event(%Key{code: code, kind: "press", modifiers: modifiers}, state)

    state
  end

  defp status_text(state) do
    {%ExRatatui.Widgets.Paragraph{text: line}, _rect} =
      state |> TUI.render(%{width: 120, height: 10}) |> List.last()

    Enum.map_join(line.spans, & &1.content)
  end

  # Feeds arriving session events through handle_info until agent_end.
  defp drain(state) do
    receive do
      {:helyx_event, %Event{} = event} ->
        {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
        if event.type == :agent_end, do: state, else: drain(state)
    after
      1_000 -> flunk("no agent_end; view model: #{inspect(state.vm)}")
    end
  end

  test "the optional-dependency guard matches what is loaded" do
    # ex_ratatui is always present in this project. The build without it is
    # checked with a scratch product, see ADR 0005.
    assert Helyx.TUI.Available.available?()
    refute Helyx.TUI.Available.__mix_recompile__?()
  end

  test "a rejected send keeps the composer text", %{core: core} do
    call = %Helyx.Message.ToolCall{
      id: "c",
      name: "slow",
      arguments: %{"ms" => 60_000, "text" => "x"}
    }

    state = mounted(core, "hold", [[call]])

    state = state |> press("g") |> press("o") |> press("enter")
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}, 1_000

    for n <- 1..32, do: :ok = Session.steer(state.session, "s#{n}")

    state = state |> press("x") |> press("enter")
    assert ExRatatui.text_input_get_value(state.input) == "x"
    assert state.vm.reason == "not sent: the queue is full"
    assert status_text(state) =~ "not sent: the queue is full"

    # The line does not wrap, so the reason comes before a long model ref.
    long = %{state | vm: %{state.vm | model: String.duplicate("m", 256)}}
    assert String.starts_with?(status_text(long), " ✕ not sent: the queue is full ")

    # The release and the repeat of the rejected Enter keep the reason.
    for kind <- ["release", "repeat"] do
      {:noreply, kept} = TUI.handle_event(%Key{code: "enter", kind: kind}, state)
      assert kept.vm.reason == "not sent: the queue is full"
    end

    # Enter again is a key press and a reject at once: the reason stays set.
    state = press(state, "enter")
    assert state.vm.reason == "not sent: the queue is full"

    # The follow-up queue has its own cap.
    for n <- 1..32, do: :ok = Session.follow_up(state.session, "f#{n}")
    state = state |> press("left") |> press("enter", ["alt"])
    assert state.vm.reason == "not sent: the queue is full"

    state = press(state, "y")
    assert state.vm.reason == nil
    assert ExRatatui.text_input_get_value(state.input) == "yx"
    refute status_text(state) =~ "not sent"
  end

  test "a paste and a modified key clear the reason", %{core: core} do
    state = mounted(core, "clear", [])

    for event <- [
          %ExRatatui.Event.Paste{content: "p"},
          %Key{code: "x", kind: "press", modifiers: ["ctrl"]}
        ] do
      rejected = %{state | vm: ViewModel.reject(state.vm, "r")}
      {:noreply, cleared} = TUI.handle_event(event, rejected)
      assert cleared.vm.reason == nil
    end
  end

  test "typing edits the composer and ignores command keys", %{core: core} do
    state = mounted(core, "typing", [])

    state = state |> press("h") |> press("i") |> press("!", ["shift"])
    assert ExRatatui.text_input_get_value(state.input) == "hi!"

    state = press(state, "backspace")
    assert ExRatatui.text_input_get_value(state.input) == "hi"

    state = state |> press("x", ["ctrl"]) |> press("f1")
    assert ExRatatui.text_input_get_value(state.input) == "hi"

    # The widget owns the cursor: Home then typing inserts at the front.
    state = state |> press("home") |> press("a")
    assert ExRatatui.text_input_get_value(state.input) == "ahi"

    {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: " there"}, state)
    assert ExRatatui.text_input_get_value(state.input) == "a therehi"
  end

  # The callbacks run in the TUI process, so a raise here is its death.
  test "invalid UTF-8 is rejected with a reason and leaves the composer unchanged", %{core: core} do
    state = mounted(core, "bad_bytes", []) |> press("h") |> press("i")

    {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: "a" <> <<0xFF>>}, state)
    state = press(state, <<0xFF>>)

    assert ExRatatui.text_input_get_value(state.input) == "hi"
    assert state.vm.cells == []
    assert state.vm.reason == "input rejected: not valid UTF-8"
    assert press(state, "!").vm.reason == nil
  end

  test "enter sends the composer and the answer streams into the view model", %{core: core} do
    state = mounted(core, "answer", [["Hello ", "there."]])

    state = state |> press("h") |> press("i") |> press("enter")
    assert ExRatatui.text_input_get_value(state.input) == ""

    state = drain(state)

    assert [%Helyx.Message{role: :user} = prompt, %Helyx.Message{role: :assistant} = answer] =
             state.vm.cells

    assert Helyx.Message.text(prompt) == "hi"
    assert Helyx.Message.text(answer) == "Hello there."
    refute state.vm.running?
  end

  test "alt+enter sends a follow-up and enter with an empty composer does nothing", %{core: core} do
    state = mounted(core, "later", [["Done."]])

    state = press(state, "enter")
    refute_receive {:helyx_event, _}, 50

    state = state |> press("g") |> press("o") |> press("enter", ["alt"])
    state = drain(state)
    assert [%Helyx.Message{role: :user}, %Helyx.Message{role: :assistant}] = state.vm.cells
  end

  test "escape aborts without blocking the caller", %{core: core} do
    state = mounted(core, "quiet", [])
    {:noreply, _state} = TUI.handle_event(%Key{code: "esc", kind: "press"}, state)
    refute_receive {:helyx_event, %Event{type: :agent_end}}, 50
  end

  test "ctrl+c stops the app", %{core: core} do
    state = mounted(core, "bye", [])
    assert {:stop, _state} = TUI.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state)
  end

  test "the TUI exits when the session dies", %{core: core} do
    state = mounted(core, "gone", [])

    Process.exit(Session.pid(state.session), :kill)
    assert_receive {:DOWN, _ref, :process, _pid, :killed} = down

    assert catch_exit(TUI.handle_info(down, state)) == {:session_down, :killed}
  end

  test "mounting on a dead session exits instead of hanging", %{core: core} do
    :ok = Fake.script(core, "dead", [])
    {:ok, session} = Session.start(core, model: "fake/dead")

    pid = Session.pid(session)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # The Registry drops the dead entry asynchronously.
    eventually(fn -> Session.pid(session) == nil end)

    assert catch_exit(TUI.mount(session: session, model: "fake/dead")) ==
             {:session_down, :noproc}
  end

  defp eventually(condition, tries \\ 100)
  defp eventually(_condition, 0), do: flunk("condition never held")

  defp eventually(condition, tries) do
    if condition.() do
      :ok
    else
      Process.sleep(5)
      eventually(condition, tries - 1)
    end
  end

  test "tool results truncate after four lines, ignoring a trailing newline" do
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{}}

    texts = fn output ->
      result = Helyx.Message.tool_result(call, {:ok, output})
      vm = %ViewModel{ViewModel.new("fake/m") | cells: [{:tool, call, result}]}
      for line <- TUI.transcript_lines(vm, 80), span <- line.spans, do: span.content
    end

    for at_or_under <- ["1\n2\n3", "1\n2\n3\n4", "1\n2\n3\n4\n"] do
      refute Enum.any?(texts.(at_or_under), &String.contains?(&1, "more"))
    end

    assert "  … 1 more line" in texts.("1\n2\n3\n4\n5")
    assert "  … 2 more lines" in texts.("1\n2\n3\n4\n5\n6")
    refute "  5" in texts.("1\n2\n3\n4\n5")
  end

  describe "wrapping by display width" do
    defp wrapped(text, width) do
      message = %Helyx.Message{role: :assistant, content: [%Helyx.Message.Text{text: text}]}
      vm = %ViewModel{ViewModel.new("fake/m") | cells: [message]}
      for line <- TUI.transcript_lines(vm, width), span <- line.spans, do: span.content
    end

    test "a narrow grapheme is one column, also with a combining mark" do
      assert wrapped(String.duplicate("a", 7), 5) == ["aaaaa", "aa"]

      assert wrapped(String.duplicate("e\u0301", 7), 5) == [
               String.duplicate("e\u0301", 5),
               String.duplicate("e\u0301", 2)
             ]
    end

    test "a CJK glyph is two columns, so no line goes past the width" do
      assert wrapped("日本語日本", 5) == ["日本", "語日", "本"]
      assert wrapped("a日本語", 5) == ["a日本", "語"]
      assert wrapped("한글ｆ", 4) == ["한글", "ｆ"]
    end

    test "an emoji, also one that a selector makes wide, is two columns" do
      for glyph <- ["\u2764\uFE0F", "✅", "👍"] do
        assert wrapped(String.duplicate(glyph, 3), 5) == [String.duplicate(glyph, 2), glyph]
      end
    end

    # ExRatatui draws each of these as two columns. The rule has no table of
    # the emoji sequences, so it counts each emoji in the grapheme.
    test "an emoji with a modifier, a joiner, or a flag is never split and never past the width" do
      thumb = "👍🏽"
      family = "👨\u200D👩\u200D👧"
      flag = "🇮🇳"

      for glyph <- [thumb, family, flag] do
        assert wrapped(String.duplicate(glyph, 3), 5) == [glyph, glyph, glyph]
      end

      assert wrapped(String.duplicate(thumb, 3), 8) == [thumb <> thumb, thumb]
    end

    test "a zero-width grapheme takes no column and stays on its line" do
      assert wrapped("abcde\u200B", 5) == ["abcde\u200B"]
    end

    test "a wide glyph at width one, and width zero, still give one glyph per line" do
      assert wrapped("日本", 1) == ["日", "本"]
      assert wrapped("ab", 0) == ["a", "b"]
    end

    test "an empty line is one empty row" do
      assert wrapped("", 5) == [""]
      assert wrapped("", 0) == [""]
    end

    # The width rule can count more columns than ExRatatui draws, never less.
    # Each line is a start, one code point, an end, and twelve "z", at width
    # 12, so the rule fills the first row to the edge with "z". When the rule
    # counts the grapheme too narrow, ExRatatui cuts a "z" from that row. The
    # starts and ends make the code point part of a grapheme of each kind:
    # after a letter, a wide glyph, a Devanagari letter, a modifier base, an
    # emoji that is no modifier base, a flag half, and a joiner, and before a
    # skin tone, a selector, and a joiner sequence.
    test "no grapheme is wider on screen than the width rule counts" do
      # U+20000 to U+3FFFD is one range of the rule: its two ends stand for it.
      # The last range is the emoji tags.
      ranges = [0x20..0x7E, 0xA0..0xD7FF, 0xE000..0x20FFF, 0x3F000..0x3FFFD, 0xE0000..0xE0FFF]
      code_points = Enum.concat(ranges)
      starts = ["a", "日", "क", "👍", "⚡", "🟠", "🇮", "👨\u200D", "\u2620\uFE0F\u200D"]
      ends = ["🏽", "\uFE0F", "\u200D👧"]
      contexts = [{"", ""}] ++ Enum.map(starts, &{&1, ""}) ++ Enum.map(ends, &{"", &1})

      for {first, last} <- contexts, chunk <- Enum.chunk_every(code_points, 4096) do
        rows =
          Enum.map(
            chunk,
            &hd(wrapped(<<first::binary, &1::utf8, last::binary, "zzzzzzzzzzzz">>, 12))
          )

        drawn = rows |> draw(12) |> String.split("\n")

        for {code, row, drawn_row} <- Enum.zip([chunk, rows, drawn]) do
          assert count_z(drawn_row) == count_z(row),
                 "#{inspect(first)}, U+#{Integer.to_string(code, 16)}, #{inspect(last)}"
        end
      end
    end

    # By code point: a prepended mark joins the next "z" into one grapheme.
    defp count_z(row), do: Enum.count(String.to_charlist(row), &(&1 == ?z))

    defp draw(rows, width) do
      height = length(rows)
      terminal = ExRatatui.init_test_terminal(width, height)
      lines = Enum.map(rows, &%Line{spans: [%Span{content: &1}]})
      area = %Rect{x: 0, y: 0, width: width, height: height}
      :ok = ExRatatui.draw(terminal, [{%Paragraph{text: lines}, area}])
      ExRatatui.get_buffer_content(terminal)
    end

    # ExRatatui cuts a row at the edge of its area. A row that the width rule
    # counts too narrow loses a glyph here.
    test "the terminal library draws every wrapped row in full" do
      text = "a日本語ｆ한글👍🏽❤\uFE0F✅🇮🇳👨\u200D👩\u200D👧e\u0301⚡zक्षिस्त्रीநிกำｶﾞ🟠〈䷀z"

      # From 4: the widest glyph of the text is a Devanagari cluster of 4 columns.
      for width <- 4..11 do
        rows = Enum.reject(wrapped(text, width), &(&1 == ""))
        drawn = rows |> draw(width) |> String.replace(" ", "")
        assert drawn == Enum.join(rows, "\n"), "width #{width}"
      end
    end
  end

  test "control characters never reach the terminal" do
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{}}
    result = Helyx.Message.tool_result(call, {:ok, "\e]0;evil\a\e[2Jcol1\tcol2\r"})

    vm = %ViewModel{
      ViewModel.new("fake/m")
      | cells: [Helyx.Message.user("hi\e[31m there"), {:tool, call, result}]
    }

    texts = for line <- TUI.transcript_lines(vm, 80), span <- line.spans, do: span.content

    assert "› hi[31m there" in texts
    assert "  ]0;evil[2Jcol1  col2" in texts
    refute Enum.any?(texts, &String.contains?(&1, "\e"))

    # Bash output is arbitrary bytes: invalid UTF-8 (a raw one-byte CSI)
    # must render, not crash. Message.tool_result scrubs the byte to the
    # replacement character before the TUI sees it.
    broken = Helyx.Message.tool_result(call, {:ok, <<"a", 0x9B, "b">>})
    vm = %ViewModel{ViewModel.new("fake/m") | cells: [{:tool, call, broken}]}
    texts = for line <- TUI.transcript_lines(vm, 80), span <- line.spans, do: span.content
    assert "  a�b" in texts
  end

  test "the transcript renders width-bounded lines with tool cells" do
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{"command" => "ls -la"}}
    result = Helyx.Message.tool_result(call, {:ok, "a\nb\nc\nd\ne\nf"})

    vm = %ViewModel{
      ViewModel.new("fake/m")
      | cells: [Helyx.Message.user("hello world"), {:tool, call, result}],
        streaming: [%Helyx.Message.Text{text: String.duplicate("s", 35)}]
    }

    lines = TUI.transcript_lines(vm, 30)
    texts = for line <- lines, span <- line.spans, do: span.content

    assert "› hello world" in texts
    assert Enum.any?(texts, &String.starts_with?(&1, "⚙ bash"))
    assert "  … 2 more lines" in texts
    assert String.duplicate("s", 30) in texts
    assert String.duplicate("s", 5) in texts
    assert Enum.all?(texts, &(String.length(&1) <= 30))
  end

  describe "scrollback" do
    # A 20 by 9 terminal: the transcript has 5 rows. Each message is one row
    # and one empty row. `resize/2` gives the terminal a new size.
    defp size, do: Process.get(:terminal_size, {20, 9})

    defp resize(state, size) do
      Process.put(:terminal_size, size)
      {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Resize{}, state)
      state
    end

    defp fold(state, type, data) do
      event = %Event{type: type, session_id: "s", turn_id: "t", seq: 0, data: data}
      {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
      state
    end

    defp scroll_state(core, count) do
      :ok = Fake.script(core, "scroll", [["ok"]])
      {:ok, session} = Session.start(core, model: "fake/scroll")

      {:ok, state} =
        TUI.mount(session: session, model: "fake/scroll", terminal_size_fn: &size/0)

      Enum.reduce(1..count//1, state, &say(&2, "m#{&1}"))
    end

    defp say(state, text), do: fold(state, :message_end, %{message: Helyx.Message.user(text)})

    defp screen(state) do
      {width, height} = size()
      [{%Paragraph{text: lines}, _rect} | _] = TUI.render(state, %{width: width, height: height})
      for line <- lines, span <- line.spans, do: span.content
    end

    test "PgUp and PgDn move one screen, new output does not move the view", %{core: core} do
      state = scroll_state(core, 10)
      assert screen(state) == ["› m9", "› m10"]
      refute status_text(state) =~ "scrolled"

      state = press(state, "page_up")
      assert screen(state) == ["› m6", "› m7", "› m8"]
      assert status_text(state) =~ "scrolled"

      state = say(state, "new")
      assert screen(state) == ["› m6", "› m7", "› m8"]

      state = press(state, "page_down")
      assert screen(state) == ["› m9", "› m10"]
      assert status_text(state) =~ "scrolled"

      state = press(state, "page_down")
      assert screen(state) == ["› m10", "› new"]
      refute status_text(state) =~ "scrolled"
    end

    test "the offset stops at the first row, and the same count of PgDn returns", %{core: core} do
      state = scroll_state(core, 6)
      up = Enum.reduce(1..50, state, fn _, acc -> press(acc, "page_up") end)
      assert screen(up) == ["› m1", "› m2", "› m3"]

      down = up |> press("page_down") |> press("page_down")
      assert down.scroll == nil
      assert screen(down) == ["› m5", "› m6"]
    end

    test "a transcript that fits the screen does not scroll", %{core: core} do
      state = core |> scroll_state(2) |> press("page_up")
      assert state.scroll == nil
      assert press(state, "page_down").scroll == nil
    end

    test "a position holds only when the rows to the end are more than one screen", %{core: core} do
      # 5 rows are one screen: a message of two rows, one of one row, and an
      # empty row after each. 4 rows and 5 rows do not scroll, 6 rows do.
      five = core |> scroll_state(0) |> say(String.duplicate("a", 30)) |> say("b")
      assert press(five, "page_up").scroll == nil
      assert press(scroll_state(core, 2), "page_up").scroll == nil
      assert press(scroll_state(core, 3), "page_up").scroll == {0, 0}
    end

    test "after a resize the row of the position is a row of its cell", %{core: core} do
      state = core |> scroll_state(0) |> say(String.duplicate("word ", 200))
      state = Enum.reduce(1..30, state, &say(&2, "m#{&1}"))
      state = Enum.reduce(1..13, state, fn _, acc -> press(acc, "page_up") end)
      assert {0, row} = state.scroll
      assert row > 20

      # At width 200 the first cell has 6 rows and the empty row.
      wide = resize(state, {200, 9})
      assert {index, row} = wide.scroll
      assert index > 0 and row < 2
      assert length(screen(wide)) in 2..3
    end

    test "an event at a moment with no terminal size returns to the newest output", %{core: core} do
      state = core |> scroll_state(10) |> press("page_up")
      Process.put(:terminal_size, {:error, :no_tty})
      assert say(state, "new").scroll == nil
    end

    test "Ctrl+End and a sent prompt return to the newest output", %{core: core} do
      state = core |> scroll_state(10) |> press("page_up")
      assert press(state, "end", ["ctrl"]).scroll == nil

      sent = state |> press("h") |> press("enter")
      assert sent.scroll == nil
      assert drain(sent).scroll == nil
    end

    test "with no terminal size the scroll keys return to the newest output", %{core: core} do
      state = scroll_state(core, 10)
      scrolled = press(state, "page_up")
      Process.put(:terminal_size, {:error, :no_tty})
      assert press(state, "page_up").scroll == nil
      assert press(scrolled, "page_up").scroll == nil
      assert press(scrolled, "page_down").scroll == nil
    end

    test "a notice while the view is in the open message keeps the row in its cell", %{core: core} do
      text = Enum.map_join(1..40, "\n", &"line#{&1}")

      state =
        core
        |> scroll_state(1)
        |> fold(:message_start, %{message: %Helyx.Message{role: :assistant, content: []}})
        |> fold(:message_update, %{text_delta: text})
        |> press("page_up")
        |> press("page_up")

      assert {1, row} = state.scroll
      {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: "/model"}, state)
      # The usage notice has three rows at width 20 and takes index 1.
      assert press(state, "enter").scroll == {2, row - 3}
    end

    test "one screen is the height minus 4 rows, and 1 row at that height or less", %{core: core} do
      for {height, rows} <- [{6, 2}, {5, 1}, {4, 1}, {3, 1}, {0, 1}] do
        Process.put(:terminal_size, {20, 9})
        state = scroll_state(core, 10)
        Process.put(:terminal_size, {20, height})
        # Row 19 is the empty row after m10, and row 18 is m10.
        assert press(state, "page_up").scroll == {div(20 - 2 * rows, 2), rem(20 - 2 * rows, 2)}
      end
    end

    test "the view moves by rows in a cell of wide glyphs, and no row is past the width",
         %{core: core} do
      # 60 glyphs of two columns at width 20: 6 rows, then the empty row.
      state = core |> scroll_state(0) |> say(String.duplicate("語", 59)) |> say("end")
      up = press(state, "page_up")
      assert up.scroll == {0, 0}

      assert screen(up) ==
               ["› " <> String.duplicate("語", 9)] ++ List.duplicate(String.duplicate("語", 10), 4)

      down = press(up, "page_down")
      assert down.scroll == nil
      glyphs = String.duplicate("語", 10)
      assert screen(down) == [glyphs, glyphs, "› end"]
    end

    test "a failed turn while the view is in the open message returns to the newest output",
         %{core: core} do
      text = Enum.map_join(1..40, "\n", &"line#{&1}")

      state =
        core
        |> scroll_state(1)
        |> fold(:message_start, %{message: %Helyx.Message{role: :assistant, content: []}})
        |> fold(:message_update, %{text_delta: text})
        |> press("page_up")
        |> press("page_up")

      assert {1, _row} = state.scroll
      assert screen(state) == Enum.map(27..31, &"line#{&1}")

      for data <- [%{stop_reason: :aborted}, %{stop_reason: :error, error: :boom}] do
        ended = fold(state, :agent_end, data)
        assert ended.scroll == nil
        assert "› m1" in screen(ended)
        refute status_text(ended) =~ "scrolled"
      end
    end

    test "a wider terminal never leaves the screen empty", %{core: core} do
      state = core |> scroll_state(0) |> say(String.duplicate("word ", 60)) |> press("page_up")
      assert {0, _row} = state.scroll

      wide = resize(state, {200, 9})
      assert wide.scroll == nil
      assert screen(wide) != []
    end
  end

  describe "/model" do
    defp submit(state, text) do
      {:noreply, state} = TUI.handle_event(%ExRatatui.Event.Paste{content: text}, state)
      press(state, "enter")
    end

    defp fold_model_change(state) do
      assert_receive {:helyx_event, %Event{type: :model_change} = event}, 1_000
      {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
      state
    end

    defp last_answer(state), do: Helyx.Message.text(List.last(state.vm.cells))

    test "a valid ref switches provider for the next turn, and back", %{core: core} do
      state = mounted(core, "switch", [["from fake"]])
      assert status_text(state) =~ "fake/switch"

      state = state |> submit("/model other/any") |> fold_model_change()
      assert ExRatatui.text_input_get_value(state.input) == ""
      assert status_text(state) =~ "other/any"
      assert Session.model(state.session) == "other/any"

      state = state |> submit("hi") |> drain()
      assert last_answer(state) == "from other"

      state = state |> submit("  /model \u00A0 fake/switch ") |> fold_model_change()
      assert status_text(state) =~ "fake/switch"
      state = state |> submit("hi") |> drain()
      assert last_answer(state) == "from fake"
    end

    test "a rejected ref shows a notice and changes nothing", %{core: core} do
      state = mounted(core, "stay", [])

      for {text, notice} <- [
            {"/model nope/any", "unknown provider: nope"},
            {"/model fake", "invalid model ref"},
            {"/model fake/" <> String.duplicate("m", 252), "invalid model ref"},
            {"/model", "usage: /model"},
            {"/model fake/a b", "invalid model ref"},
            {"/model\u00A0fake/a\u00A0b", "invalid model ref"},
            {"/model \u00A0 ", "usage: /model"}
          ] do
        ExRatatui.text_input_set_value(state.input, "")
        state = submit(state, text)

        assert {:notice, shown} = List.last(state.vm.cells)
        assert shown =~ notice
        # At most the provider id: never the whole ref, whatever its size.
        assert byte_size(shown) < 80
        assert ExRatatui.text_input_get_value(state.input) == text
        assert status_text(state) =~ "fake/stay"
        assert Session.model(state.session) == "fake/stay"
      end

      refute_receive {:helyx_event, _}, 50
    end

    test "a line that starts with /model but has no separator shows usage and is never sent",
         %{core: core} do
      state = mounted(core, "plain", [["ok"]])

      # The widget drops a pasted tab, so the third line arrives as "/modelfake/x".
      for text <- ["/models are fun", "/model-x", "/model\tfake/x"] do
        ExRatatui.text_input_set_value(state.input, "")
        state = submit(state, text)
        assert {:notice, "usage: /model" <> _} = List.last(state.vm.cells)
        assert ExRatatui.text_input_get_value(state.input) != ""
      end

      refute_receive {:helyx_event, _}, 50

      # A slash elsewhere, or another first word, is a message.
      ExRatatui.text_input_set_value(state.input, "")
      state = state |> submit("see /model") |> drain()
      assert last_answer(state) == "ok"
    end

    test "during a turn, with Enter or Alt+Enter, the command is never queued", %{core: core} do
      call = %Helyx.Message.ToolCall{
        id: "c",
        name: "slow",
        arguments: %{"ms" => 60_000, "text" => "x"}
      }

      state = mounted(core, "busy", [[call]])
      state = submit(state, "go")
      assert_receive {:helyx_event, %Event{type: :tool_execution_start}}, 1_000

      for {text, model} <- [{"/model other/any", "other/any"}, {"/model fake/busy", "fake/busy"}] do
        {:noreply, _} = TUI.handle_event(%ExRatatui.Event.Paste{content: text}, state)
        press(state, "enter", if(model == "other/any", do: ["alt"], else: []))
        assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: ^model}}}
        assert ExRatatui.text_input_get_value(state.input) == ""
      end

      # A rejected command stays in the composer, and nothing joins a queue.
      {:noreply, _} = TUI.handle_event(%ExRatatui.Event.Paste{content: "/model nope/x"}, state)
      state = press(state, "enter", ["alt"])
      assert {:notice, "unknown provider: nope"} = List.last(state.vm.cells)
      assert ExRatatui.text_input_get_value(state.input) == "/model nope/x"
      assert Session.queue_count(state.session) == %{steers: 0, follow_ups: 0}
      refute_receive {:helyx_event, %Event{type: :queue_update}}, 50

      :ok = Session.abort(state.session)
    end

    test "the rule is on bytes: a line that only looks like the command is a message", %{
      core: core
    } do
      # The stated limit of the rule (feature doc, bounds table): an invisible
      # character inside the word, one outside category C before it, and a
      # homoglyph each make a message.
      lines = ["/mo\u200Bdel other/any", "\u3164/model other/any", "/mo\u0434el other/any"]
      state = mounted(core, "looks", Enum.map(lines, fn _ -> ["ok"] end))

      for text <- lines do
        ExRatatui.text_input_set_value(state.input, "")
        state = state |> submit(text) |> drain()
        assert last_answer(state) == "ok"
        assert Session.model(state.session) == "fake/looks"
      end
    end

    test "invisible characters around the command word do not hide it", %{core: core} do
      state = mounted(core, "bom", [])

      for text <- [
            "\uFEFF/model other/any",
            "/model\u200Bother/any",
            "\u2060 /model\u180E other/any"
          ] do
        :ok = Session.set_model(state.session, "fake/bom")
        assert_receive {:helyx_event, %Event{type: :model_change}}
        ExRatatui.text_input_set_value(state.input, "")
        submit(state, text)
        assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: "other/any"}}}
        assert ExRatatui.text_input_get_value(state.input) == ""
      end

      # Inside the ref, or after it, such a character is the ref's problem:
      # it is not trimmed, so the ref is rejected, and nothing is sent.
      for text <- ["/model fake/a\u200Bb", "/model fake/ab\u200B"] do
        ExRatatui.text_input_set_value(state.input, "")
        state = submit(state, text)
        assert {:notice, "invalid model ref" <> _} = List.last(state.vm.cells)
        assert ExRatatui.text_input_get_value(state.input) == text
      end

      refute_receive {:helyx_event, _}, 50
    end
  end
end
