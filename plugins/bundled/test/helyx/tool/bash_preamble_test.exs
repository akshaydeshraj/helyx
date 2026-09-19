defmodule Helyx.Tool.Bash.PreambleTest do
  # With a locale the system does not have, perl writes a startup warning to
  # stderr before the watchdog's marker line. Not async: the locale is in the
  # OS environment of the whole VM.
  use ExUnit.Case, async: false

  import Helyx.Tool.Bash.OSHelpers

  @moduletag :tmp_dir

  setup do
    put_env("LC_ALL", "xx_NOPE.UTF-8")
  end

  defp put_env(name, value) do
    old = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if old, do: System.put_env(name, old), else: System.delete_env(name)
    end)
  end

  test "the not-started marker is found after perl's own warnings (issue #52)", %{tmp_dir: dir} do
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, Path.join(dir, "gone"))
    assert text =~ "did not start"
  end

  test "warnings over the preamble limit: the command does not run", %{tmp_dir: dir} do
    # perl prints the value of every locale variable in its warning.
    put_env("LC_MESSAGES", String.duplicate("x", 5000))
    ran = Path.join(dir, "ran")

    for cwd <- [dir, Path.join(dir, "gone")] do
      assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "touch #{ran}"}, cwd)
      assert text =~ "did not start"
    end

    refute File.exists?(ran)
  end

  test "the close with no marker leaves no process", %{tmp_dir: dir} do
    put_env("LC_MESSAGES", String.duplicate("x", 5000))
    test = self()

    # Stands in for the hands: it takes the group registrations.
    hands =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:register_group, group, kind}} ->
            send(test, {:registered, group, kind})
            GenServer.reply(from, :ok)
        end
      end)

    Process.put(:helyx_hands, hands)
    assert {:error, _} = Helyx.Tool.Bash.run(%{"command" => "sleep 30"}, dir)
    assert_received {:registered, watchdog, :watchdog}
    # The watchdog reaps the child it holds before it exits.
    assert gone_within?("-#{watchdog}", 200)
  end

  test "a line from the environment cannot pass for a marker", %{tmp_dir: dir} do
    put_env("LC_ALL", "xx\n4242\n0\nyy")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, Path.join(dir, "gone"))
    assert text =~ "cannot enter"
    assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
    assert text =~ "ran\n"
  end

  test "a perl that stops before the watchdog runs is an error, not its exit code",
       %{tmp_dir: dir} do
    put_env("PERL5OPT", "-MNopeNope")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, dir)
    assert text =~ "did not start"
    assert text =~ "NopeNope"
  end

  # An executable file whose interpreter does not exist: it is found, and
  # the exec fails.
  defp put_bad_bash(dir) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "bash"), "#!/nonexistent/interpreter\n")
    File.chmod!(Path.join(bin, "bash"), 0o755)
    put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    Path.join(bin, "bash")
  end

  test "a bash that cannot be executed is an error, not exit code 127 (issue #70)",
       %{tmp_dir: dir} do
    # The path holds characters of two and of three bytes: the reason is
    # bytes already, and it must arrive as it is.
    bash = put_bad_bash(Path.join(dir, "é☃"))
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
    assert text =~ "did not start"
    assert text =~ "cannot run #{bash}: No such file"
    refute text =~ " 0\n"
  end

  test "perl's warning about the exec, in front of the report, is still an error (issue #70)",
       %{tmp_dir: dir} do
    bash = put_bad_bash(dir)
    put_env("PERL5OPT", "-w")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
    assert text =~ "Can't exec"
    assert text =~ "cannot run #{bash}: No such file"
    refute text =~ " 0\n"
  end

  test "PERL_UNICODE=A and a wide character in the bash path: still an error (issue #70)",
       %{tmp_dir: dir} do
    # perl decodes its arguments, so the reason holds a wide character, and
    # a write of wide characters to the binary report pipe is fatal.
    bash = put_bad_bash(Path.join(dir, "é☃"))
    put_env("PERL_UNICODE", "A")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
    assert text =~ "did not start: "
    assert text =~ "cannot run #{bash}: No such file"
    refute text =~ "Wide character"
  end

  test "PERL_UNICODE=i: the held child dies and the result is an error, not exit code 255 (issue #70)",
       %{tmp_dir: dir} do
    put_env("PERL_UNICODE", "i")
    ran = Path.join(dir, "ran")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "touch #{ran}"}, dir)
    assert text =~ "did not start"
    assert text =~ ":utf8 handles"
    refute text =~ " 0\n"
    refute File.exists?(ran)
  end

  test "the group marker is found after perl's own warnings", %{tmp_dir: dir} do
    assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo $$; ps -o pgid= -p $$"}, dir)
    # The marker line is gone from the output: what is left of the numbers
    # is the command's own pid and its group, which are equal.
    assert [pid, pgid] = Regex.scan(~r/^\s*(\d+)\s*$/m, text, capture: :all_but_first)
    assert pid == pgid
  end
end
