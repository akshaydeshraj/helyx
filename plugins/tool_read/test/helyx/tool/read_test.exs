defmodule Helyx.Tool.ReadTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Read]})

    %{
      run: fn args ->
        Fake.run_tool(core, %ToolCall{id: "c", name: "read", arguments: args}, dir)
      end
    }
  end

  test "returns the content of a file relative to the working directory", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    result = run.(%{"path" => "a.txt"})
    refute result.is_error
    assert Helyx.Message.text(result) == "one\ntwo\n"
  end

  test "truncates a long file to its head and names the next offset", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..3000, "\n", &to_string/1))
    text = Helyx.Message.text(run.(%{"path" => "long.txt"}))
    assert String.starts_with?(text, "1\n2\n")

    assert String.ends_with?(
             text,
             "2000\n[truncated: showing lines 1-2000 of 3000; read again with offset 2001]"
           )
  end

  test "offset reads from a later line", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree")
    assert Helyx.Message.text(run.(%{"path" => "a.txt", "offset" => 2})) == "two\nthree"
  end

  test "a truncated offset read reports absolute lines and continues with no gap", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..5000, "\n", &to_string/1))

    first = Helyx.Message.text(run.(%{"path" => "long.txt", "offset" => 2001}))
    assert String.starts_with?(first, "2001\n")

    assert String.ends_with?(
             first,
             "4000\n[truncated: showing lines 2001-4000 of 5000; read again with offset 4001]"
           )

    second = Helyx.Message.text(run.(%{"path" => "long.txt", "offset" => 4001}))
    assert String.starts_with?(second, "4001\n")
    assert String.ends_with?(second, "\n5000")
  end

  test "a missing file is an error result", %{run: run} do
    result = run.(%{"path" => "nope.txt"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read nope.txt: no such file or directory"
  end

  test "a device file is an error result, not a hang", %{run: run} do
    result = run.(%{"path" => "/dev/zero"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read /dev/zero: not a regular file (device)"
  end

  test "a file over the size limit is an error result", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "big.bin"), :binary.copy(<<0>>, 10_485_761))
    result = run.(%{"path" => "big.bin"})
    assert result.is_error

    assert Helyx.Message.text(result) ==
             "cannot read big.bin: over the 10485760-byte limit"
  end

  test "a file that is not valid UTF-8 is an error result", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "raw.bin"), <<255, 254>>)
    result = run.(%{"path" => "raw.bin"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read raw.bin: binary file, 2 bytes"
  end

  test "missing arguments are an error result", %{run: run} do
    assert run.(%{}).is_error
  end
end
