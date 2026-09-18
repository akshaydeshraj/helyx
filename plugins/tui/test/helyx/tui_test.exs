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
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]})
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
end
