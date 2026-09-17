defmodule Helyx.ModelContext.DefaultTest do
  use ExUnit.Case, async: true

  alias Helyx.ModelContext.Default

  @moduletag :tmp_dir

  defp system(home, cwd) do
    %Helyx.Context{system: system} = Default.build(%Helyx.Context{}, cwd: cwd, home: home)
    system
  end

  test "concatenates AGENTS.md from home down to the working directory", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(home, "code/proj")
    File.mkdir_p!(cwd)
    File.write!(Path.join(home, "AGENTS.md"), "home rules")
    File.write!(Path.join(home, "code/AGENTS.md"), "code rules")
    File.write!(Path.join(cwd, "AGENTS.md"), "proj rules")

    system = system(home, cwd)

    assert system =~ "#{Path.join(home, "AGENTS.md")}\n\nhome rules"
    assert system =~ "#{Path.join(home, "code/AGENTS.md")}\n\ncode rules"
    assert system =~ "#{Path.join(cwd, "AGENTS.md")}\n\nproj rules"
    assert system =~ ~r/home rules.*code rules.*proj rules/s
  end

  test "a level without AGENTS.md is skipped without error", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(home, "code/proj")
    File.mkdir_p!(cwd)
    File.write!(Path.join(home, "AGENTS.md"), "home rules")
    File.write!(Path.join(cwd, "AGENTS.md"), "proj rules")

    system = system(home, cwd)

    assert system =~ "home rules"
    assert system =~ "proj rules"
    refute system =~ Path.join(home, "code/AGENTS.md")
  end

  test "no AGENTS.md anywhere gives the base prompt alone", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(home, "code")
    File.mkdir_p!(cwd)

    system = system(home, cwd)

    assert system != ""
    refute system =~ "AGENTS.md"
  end

  test "a working directory that is the home directory reads it once", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "AGENTS.md"), "home rules")

    system = system(home, home)

    assert length(String.split(system, "home rules")) == 2
  end

  test "an AGENTS.md that is not valid UTF-8 is skipped without error", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(home, "code")
    File.mkdir_p!(cwd)
    File.write!(Path.join(home, "AGENTS.md"), <<0xFF, 0xFE, "not utf8">>)
    File.write!(Path.join(cwd, "AGENTS.md"), "code rules")

    system = system(home, cwd)

    assert system =~ "code rules"
    refute system =~ Path.join(home, "AGENTS.md") <> "\n"
  end

  test "a long AGENTS.md is truncated on whole lines", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    lines = Enum.map_join(1..3000, "\n", &"line #{&1}")
    File.write!(Path.join(home, "AGENTS.md"), lines)

    system = system(home, home)

    assert system =~ "line 1\n"
    assert system =~ ~r/\[truncated: showing lines 1-\d+ of 3000\]/
    refute system =~ "line 3000"
  end

  test "a working directory outside home contributes only its own AGENTS.md", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(dir, "elsewhere")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)
    File.write!(Path.join(home, "AGENTS.md"), "home rules")
    File.write!(Path.join(cwd, "AGENTS.md"), "elsewhere rules")

    system = system(home, cwd)

    assert system =~ "elsewhere rules"
    refute system =~ "home rules"
  end
end
