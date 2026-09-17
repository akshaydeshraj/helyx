defmodule Helyx.Tool.EditTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Edit]})
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree\n")

    %{
      run: fn args ->
        Helyx.Provider.Fake.run_tool(core, %ToolCall{id: "c", name: "edit", arguments: args}, dir)
      end
    }
  end

  test "replaces one exact occurrence", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "a.txt", "old_text" => "two\n", "new_text" => "2\n2b\n"})
    refute result.is_error
    assert Helyx.Message.text(result) == "Edited a.txt"
    assert File.read!(Path.join(dir, "a.txt")) == "one\n2\n2b\nthree\n"
  end

  test "absent text is an error and the file is untouched", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "a.txt", "old_text" => "four", "new_text" => "x"})
    assert result.is_error
    assert Helyx.Message.text(result) == "old_text not found in a.txt"
    assert File.read!(Path.join(dir, "a.txt")) == "one\ntwo\nthree\n"
  end

  test "ambiguous text is an error and the file is untouched", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "a.txt", "old_text" => "t", "new_text" => "x"})
    assert result.is_error
    assert Helyx.Message.text(result) == "old_text matches 2 places in a.txt; make it unique"
    assert File.read!(Path.join(dir, "a.txt")) == "one\ntwo\nthree\n"
  end

  test "empty old_text is an error", %{run: run} do
    assert Helyx.Message.text(run.(%{"path" => "a.txt", "old_text" => "", "new_text" => "x"})) ==
             "old_text is empty"
  end

  test "a directory is an error result", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => dir, "old_text" => "a", "new_text" => "b"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read #{dir}: not a regular file (directory)"
  end

  test "a missing file is an error result", %{run: run} do
    result = run.(%{"path" => "nope", "old_text" => "a", "new_text" => "b"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read nope: no such file or directory"
  end
end
