defmodule Helyx.SessionTest do
  # Session seam with a test provider whose streams end badly. The happy path
  # lives in the Fake provider plugin's tests.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Session}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Test.Provider]})
    %{core: core}
  end

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      1_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp stop_reason(events), do: List.last(events).data.stop_reason

  test "a stream that ends without a terminal event ends the turn with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/empty")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == :stream_ended

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  @tag :capture_log
  test "a task crash fails the turn and the session accepts the next prompt", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert {:task_exit, {%RuntimeError{message: "boom"}, _}} = List.last(events).data.error

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  test "consumption stops at the first terminal event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/overrun")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert Helyx.Message.text(Enum.find(events, &(&1.type == :turn_end)).data.message) == "kept"
    refute_receive {:helyx_event, _}, 100
  end

  test "a prompt during a turn is rejected", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert {:error, :turn_running} = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end
end
