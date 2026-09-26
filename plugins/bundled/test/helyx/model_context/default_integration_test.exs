defmodule Helyx.ModelContext.DefaultIntegrationTest do
  # The seam through the session: the provider receives the assembled system
  # prompt when the Default plugin is registered.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Session}

  @tag :tmp_dir
  test "the Fake provider receives the assembled system prompt", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "rules for #{dir}")

    core = :"core_#{System.unique_integer([:positive])}"
    plugins = [Helyx.Provider.Fake, Helyx.ModelContext.Default]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})

    {:ok, session} = Session.start(core, model: "fake/system", cwd: dir)
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")

    text = Helyx.Message.text(collect(:turn_end).data.message)
    assert text =~ "You are a coding agent."
    assert text =~ "## #{Path.join(Path.expand(dir), "AGENTS.md")}\n\nrules for #{dir}"
  end

  defp collect(type) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> event
      {:helyx_event, %Event{}} -> collect(type)
    after
      1_000 -> flunk("timed out waiting for #{type}")
    end
  end
end
