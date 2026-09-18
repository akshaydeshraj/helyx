defmodule Helyx.Tool.WriteTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Write]})

    %{
      run: fn args ->
        Fake.run_tool(
          core,
          %ToolCall{id: "c", name: "write", arguments: args},
          dir
        )
      end
    }
  end

  test "creates a file and its directories", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "sub/dir/a.txt", "content" => "hello"})
    refute result.is_error
    assert Helyx.Message.text(result) == "Wrote sub/dir/a.txt"
    assert File.read!(Path.join(dir, "sub/dir/a.txt")) == "hello"
  end

  test "replaces an existing file", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "a.txt"), "old")
    refute run.(%{"path" => "a.txt", "content" => "new"}).is_error
    assert File.read!(Path.join(dir, "a.txt")) == "new"
  end

  test "a path under a file is an error result", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "file"), "")
    result = run.(%{"path" => "file/a.txt", "content" => "x"})
    assert result.is_error
    assert Helyx.Message.text(result) =~ "cannot write file/a.txt"
  end

  test "missing arguments are an error result", %{run: run} do
    assert run.(%{"path" => "a.txt"}).is_error
  end
end
