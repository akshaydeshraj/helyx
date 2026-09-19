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

  test "wrapping counts graphemes and survives width zero" do
    vm = %ViewModel{
      ViewModel.new("fake/m")
      | cells: [Helyx.Message.user(String.duplicate("é", 7))]
    }

    texts = for line <- TUI.transcript_lines(vm, 5), span <- line.spans, do: span.content
    assert ("› " <> String.duplicate("é", 3)) in texts
    assert String.duplicate("é", 4) in texts

    assert TUI.transcript_lines(vm, 0) != []
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

    defp status_text(state) do
      [_transcript, _composer, {%{text: %{spans: [span | _]}}, _area}] =
        TUI.render(state, %{width: 80, height: 24})

      span.content
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
