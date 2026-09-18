defmodule CodingAgentTest do
  # The TUI needs a terminal, so the test drives the same wiring headless:
  # Core with the product's plugin list, a session, a turn with a tool call.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message, Session}

  test "the plugin list boots Core and a session runs a tool-call turn" do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "echo hi"}}
    :ok = Helyx.Provider.Fake.script(core, "task", [["Running.", call], ["Done."]])

    {:ok, session} = Session.start(core, model: "fake/task")
    :ok = Session.subscribe(session)
    :ok = Session.prompt(session, "run it")

    events = collect_until(:agent_end)
    types = Enum.map(events, & &1.type)
    assert :tool_execution_start in types
    assert :tool_execution_end in types

    result =
      Enum.find_value(events, fn
        %{type: :tool_execution_end, data: %{message: message}} -> message
        _ -> nil
      end)

    assert Message.text(result) =~ "hi"
    assert Message.text(Enum.find(events, &(&1.type == :turn_end)).data.message) == "Done."
  end

  test "a bad model ref is rejected before anything starts" do
    core = :"agent_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: CodingAgent.plugins()})

    assert {:error, _reason} = Session.start(core, model: "not-a-ref")
  end

  test "mix helyx rejects bad arguments before starting anything" do
    assert_raise Mix.Error, ~r/--bogus/, fn -> Mix.Tasks.Helyx.run(["--bogus"]) end
    assert_raise Mix.Error, ~r/at most one directory/, fn -> Mix.Tasks.Helyx.run(["a", "b"]) end

    assert_raise Mix.Error, ~r/not a directory/, fn ->
      Mix.Tasks.Helyx.run(["/nonexistent/helyx-test-dir"])
    end
  end

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      5_000 -> flunk("timed out waiting for #{type}")
    end
  end
end
