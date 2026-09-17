defmodule Helyx.Tool.BashTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Bash]})

    %{
      run: fn args ->
        Helyx.Provider.Fake.run_tool(core, %ToolCall{id: "c", name: "bash", arguments: args}, dir)
      end
    }
  end

  test "runs in the working directory and merges stderr", %{tmp_dir: dir, run: run} do
    result = run.(%{"command" => "pwd; echo err >&2"})
    refute result.is_error
    assert Helyx.Message.text(result) == "#{dir}\nerr\n"
  end

  test "a non-zero exit code is in the text, not an error result", %{run: run} do
    result = run.(%{"command" => "echo partial; exit 3"})
    refute result.is_error
    assert Helyx.Message.text(result) == "partial\n\nExit code: 3"
  end

  test "no output says so", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "true"})) == "(no output)"
  end

  test "long output is cut from the head end and says so", %{run: run} do
    text = Helyx.Message.text(run.(%{"command" => "seq 1 3000"}))
    assert String.starts_with?(text, "[truncated: showing lines 1001-3000 of 3000]\n1001\n")
  end

  test "the command runs in its own process group", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "ps -o pgid= -p $$ | tr -d ' '; echo $$"})) =~
             ~r/^(\d+)\n\1\n$/
  end

  test "the command does not wait on stdin", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "cat"})) == "(no output)"
  end

  test "missing arguments are an error result", %{run: run} do
    assert run.(%{}).is_error
  end
end
