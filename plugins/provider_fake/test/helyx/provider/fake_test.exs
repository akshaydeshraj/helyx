defmodule Helyx.Provider.FakeTest do
  # Session seam: drive a session through its public API with the Fake
  # provider and assert only on the events a client would see.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Session}

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake]})
    %{core: core}
  end

  defp final_message(events) do
    Enum.find(events, &(&1.type == :turn_end)).data.message
  end

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      1_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  test "one prompt runs one turn and emits the loop events in order", %{core: core} do
    {:ok, session} = Session.start(core, model: "fake/echo")
    :ok = Session.subscribe(session)
    :ok = Session.prompt(session, "hello there")

    events = collect_until(:agent_end)

    assert Enum.map(events, & &1.type) == [
             :agent_start,
             :turn_start,
             :message_start,
             :message_end,
             :message_start,
             :message_update,
             :message_update,
             :message_end,
             :turn_end,
             :agent_end
           ]

    assert Enum.map(events, & &1.seq) == Enum.to_list(1..10)
    assert Enum.all?(events, &(&1.session_id == session.id))
    assert [turn_id] = events |> Enum.map(& &1.turn_id) |> Enum.uniq()
    assert is_binary(turn_id)

    [_, _, user_start, _, _, delta1, delta2, assistant_end | _] = events
    assert %Helyx.Message{role: :user} = user_start.data.message
    assert delta1.data.delta == "hello"
    assert delta2.data.delta == " there"
    assert %Helyx.Message{role: :assistant, model: "fake/echo"} = assistant_end.data.message
    assert Helyx.Message.text(assistant_end.data.message) == "hello there"
  end

  test "a scripted model replays its responses in order", %{core: core} do
    :ok = Helyx.Provider.Fake.script(core, "scripted", [["one"], ["two", " and", " three"]])
    {:ok, session} = Session.start(core, model: "fake/scripted")
    :ok = Session.subscribe(session)

    :ok = Session.prompt(session, "first")
    first = collect_until(:agent_end)
    assert Helyx.Message.text(final_message(first)) == "one"

    :ok = Session.prompt(session, "second")
    second = collect_until(:agent_end)
    assert Helyx.Message.text(final_message(second)) == "two and three"
    assert hd(second).seq == length(first) + 1
  end

  test "two sessions run at once without interfering", %{core: core} do
    {:ok, a} = Session.start(core, model: "fake/echo")
    {:ok, b} = Session.start(core, model: "fake/echo")
    :ok = Session.subscribe(a)
    :ok = Session.subscribe(b)
    :ok = Session.prompt(a, "alpha")
    :ok = Session.prompt(b, "beta")

    events = collect_until(:agent_end) ++ collect_until(:agent_end)
    by_session = Enum.group_by(events, & &1.session_id)

    assert map_size(by_session) == 2
    assert Enum.map(by_session[a.id], & &1.seq) == Enum.to_list(1..9)
    assert Enum.map(by_session[b.id], & &1.seq) == Enum.to_list(1..9)
    assert Helyx.Message.text(final_message(by_session[a.id])) == "alpha"
    assert Helyx.Message.text(final_message(by_session[b.id])) == "beta"
  end

  test "an unknown provider prefix is rejected at start", %{core: core} do
    assert {:error, {:unknown_provider, "nope"}} = Session.start(core, model: "nope/x")
  end
end
