defmodule Helyx.SessionFileTest do
  use ExUnit.Case, async: true

  alias Helyx.{Message, SessionFile}

  @moduletag :tmp_dir

  test "create writes a header and resume restores the empty session", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert resumed.session_id == "sess1"
    assert resumed.model == "test/ok"
    assert resumed.messages == []
    assert resumed.file.path == file.path
  end

  test "resume with no session for the directory", %{tmp_dir: dir} do
    assert {:error, :not_found} = SessionFile.resume(dir, "/repo")
  end

  test "messages round-trip through the file", %{tmp_dir: dir} do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}

    assistant = %Message{
      role: :assistant,
      model: "test/ok",
      stop_reason: :tool_use,
      usage: %{"input" => 12, "output" => 3},
      content: [
        %Message.Thinking{thinking: "hmm", signature: "sig"},
        %Message.Text{text: "Listing."},
        call
      ]
    }

    result = %Message{
      role: :tool_result,
      tool_call_id: "c1",
      tool_name: "bash",
      is_error: true,
      content: [
        %Message.Text{text: "no such directory"},
        %Message.Image{mime_type: "image/png", data: "aGk="}
      ]
    }

    messages = [Message.user("List the tests."), assistant, result]

    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    Enum.reduce(messages, file, &SessionFile.append_message(&2, &1))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert resumed.messages == messages
  end

  test "a model change entry is written and restored", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    SessionFile.append_model_change(file, "test/other")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert resumed.model == "test/other"
  end

  test "a header with an unknown or missing version is rejected", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    header = File.read!(file.path)

    File.write!(file.path, String.replace(header, ~s("version":1), ~s("version":99)))
    assert {:error, {:unknown_version, 99}} = SessionFile.resume(dir, "/repo")

    File.write!(file.path, String.replace(header, ~s("version"), ~s("gone")))
    assert {:error, {:unknown_version, nil}} = SessionFile.resume(dir, "/repo")
  end

  test "a torn last line is repaired and the next append is valid", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    file = SessionFile.append_message(file, Helyx.Message.user("kept"))
    File.write!(file.path, ~s({"id":"x","type":"mess), [:append])

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert [%Message{role: :user}] = resumed.messages

    SessionFile.append_message(resumed.file, Message.user("after"))
    assert {:ok, repaired} = SessionFile.resume(dir, "/repo")
    assert Enum.map(repaired.messages, &Message.text/1) == ["kept", "after"]
  end

  test "a torn last line after multibyte content is repaired at the right byte", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    file = SessionFile.append_message(file, Message.user("héllo — ünïcode ✓"))
    File.write!(file.path, ~s({"torn), [:append])

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")

    SessionFile.append_message(resumed.file, Message.user("after"))
    assert {:ok, repaired} = SessionFile.resume(dir, "/repo")
    assert Enum.map(repaired.messages, &Message.text/1) == ["héllo — ünïcode ✓", "after"]
  end

  test "a rejected file is not repaired", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, ~s({"id":"x","type":"note"}) <> "\n" <> ~s({"torn), [:append])
    before = File.read!(file.path)

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
    assert File.read!(file.path) == before
  end

  test "a complete last entry missing only its newline is repaired", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    file = SessionFile.append_message(file, Message.user("kept"))
    File.write!(file.path, String.trim_trailing(File.read!(file.path), "\n"))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")

    SessionFile.append_message(resumed.file, Message.user("after"))
    assert {:ok, repaired} = SessionFile.resume(dir, "/repo")
    assert Enum.map(repaired.messages, &Message.text/1) == ["kept", "after"]
  end

  test "resume picks the most recently started session for the directory", %{tmp_dir: dir} do
    {:ok, _} = SessionFile.create(dir, "older", "/repo", "test/ok")
    {:ok, _} = SessionFile.create(dir, "newer", "/repo", "test/ok")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
    assert resumed.session_id == "newer"
  end

  test "two directories with one slug do not cross", %{tmp_dir: dir} do
    {:ok, _} = SessionFile.create(dir, "sess1", "/repo/a-b", "test/ok")
    {:ok, _} = SessionFile.create(dir, "sess2", "/repo/a/b", "test/ok")

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo/a-b")
    assert resumed.session_id == "sess1"
  end

  test "an entry with a shape this module never writes is rejected, not raised", %{tmp_dir: dir} do
    bad = ~s({"id":"x","parent_id":null,"ts":"t","type":"message","role":"system","content":[]})
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, bad <> "\n", [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
  end

  test "an unwritable directory is an error, not a raise", %{tmp_dir: dir} do
    not_a_dir = Path.join(dir, "flat")
    File.write!(not_a_dir, "")

    assert {:error, {:create_failed, _}} =
             SessionFile.create(not_a_dir, "sess1", "/repo", "test/ok")
  end

  test "a long working directory path still gets a file", %{tmp_dir: dir} do
    cwd = "/" <> String.duplicate("deep/", 80)
    {:ok, _} = SessionFile.create(dir, "sess1", cwd, "test/ok")

    assert {:ok, resumed} = SessionFile.resume(dir, cwd)
    assert resumed.session_id == "sess1"
  end

  test "a bad line mid-file is rejected and nothing is truncated", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, "not json\n", [:append])
    SessionFile.append_message(file, Message.user("kept"))
    before = File.read!(file.path)

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
    assert File.read!(file.path) == before
  end

  test "a repair that cannot write is an environment error", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, ~s({"torn), [:append])
    File.chmod!(file.path, 0o444)

    assert {:error, {:repair_failed, :eacces}} = SessionFile.resume(dir, "/repo")
    File.chmod!(file.path, 0o644)
  end

  test "a model that is missing or not a string is rejected", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, ~s({"id":"x","type":"model_change","model":42}) <> "\n", [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")

    {:ok, file2} = SessionFile.create(dir, "sess2", "/repo2", "test/ok")
    File.write!(file2.path, ~s({"id":"x","type":"model_change"}) <> "\n", [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo2")

    # A later valid change does not launder a bad one mid-file.
    {:ok, file3} = SessionFile.create(dir, "sess3", "/repo3", "test/ok")
    File.write!(file3.path, ~s({"id":"x","type":"model_change","model":42}) <> "\n", [:append])
    SessionFile.append_model_change(file3, "test/other")

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo3")

    # Nor a bad header model.
    {:ok, file4} = SessionFile.create(dir, "sess4", "/repo4", "test/ok")
    header = File.read!(file4.path)
    File.write!(file4.path, String.replace(header, ~s("model":"test/ok"), ~s("model":42)))
    SessionFile.append_model_change(file4, "test/other")

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo4")
  end

  test "resume decodes stop reasons in a VM that never interned their atoms", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")

    SessionFile.append_message(file, %Message{
      role: :assistant,
      stop_reason: :max_tokens,
      content: [%Message.Text{text: "t"}]
    })

    script = """
    {:ok, resumed} = Helyx.SessionFile.resume(#{inspect(dir)}, "/repo")
    [%{stop_reason: :max_tokens}] = resumed.messages
    IO.puts("resumed ok")
    """

    ebin = Path.join(Mix.Project.build_path(), "lib/helyx/ebin")
    assert {out, 0} = System.cmd("elixir", ["-pa", ebin, "-e", script])
    assert out =~ "resumed ok"
  end

  test "a stop reason outside the format's set is never written", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    before = File.read!(file.path)

    assert_raise FunctionClauseError, fn ->
      SessionFile.append_message(file, %Message{
        role: :assistant,
        stop_reason: :aborted,
        content: []
      })
    end

    assert File.read!(file.path) == before
  end

  test "resume caps an integer over the digit limit in tool call arguments and usage", %{
    tmp_dir: dir
  } do
    call = fn n -> %Message.ToolCall{id: "c1", name: "read", arguments: %{"offset" => [n]}} end

    message = fn n ->
      %Message{role: :assistant, content: [call.(n)], stop_reason: :tool_use, usage: %{"in" => n}}
    end

    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    file = SessionFile.append_message(file, message.(10 ** 100))
    SessionFile.append_message(file, message.(10 ** 100 - 1))

    assert {:ok, resumed} = SessionFile.resume(dir, "/repo")

    assert [["integer of more than 100 digits removed"], [10 ** 100 - 1]] ==
             for(%Message{content: [block]} <- resumed.messages, do: block.arguments["offset"])

    assert ["integer of more than 100 digits removed", 10 ** 100 - 1] ==
             for(%Message{usage: usage} <- resumed.messages, do: usage["in"])
  end

  test "a message field with a wrong type is rejected", %{tmp_dir: dir} do
    entry = ~s({"id":"x","type":"message","role":"tool_result","tool_call_id":42,"content":[]})
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, entry <> "\n", [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
  end

  test "a stop reason outside the format's set is rejected", %{tmp_dir: dir} do
    entry = ~s({"id":"x","type":"message","role":"assistant","stop_reason":"banana","content":[]})
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, entry <> "\n", [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
  end

  test "a content block with a wrong field type is rejected", %{tmp_dir: dir} do
    entry = ~s({"id":"x","type":"message","role":"user","content":[{"type":"text","text":42}]})
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, entry <> "\n", [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
  end

  test "an entry type the writer never produces is rejected", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, ~s({"id":"x","type":"note"}) <> "\n", [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
  end

  test "a second header mid-file is rejected", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, File.read!(file.path), [:append])

    assert {:error, {:invalid_file, _}} = SessionFile.resume(dir, "/repo")
  end

  describe "the file size limit" do
    test "a file at the limit resumes; one byte over is rejected and not mutated",
         %{tmp_dir: dir} do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
      # Multibyte content: the limit counts bytes, not characters.
      SessionFile.append_message(file, Message.user("héllo wörld"))
      size = File.stat!(file.path).size

      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_bytes: size + 1)
      assert {:ok, resumed} = SessionFile.resume(dir, "/repo", max_bytes: size)
      assert [%Message{role: :user}] = resumed.messages

      # One byte over. A torn tail would be repaired on an accepted file;
      # here it must stay.
      File.write!(file.path, "{", [:append])
      before = File.read!(file.path)

      assert {:error, {:too_large, text}} = SessionFile.resume(dir, "/repo", max_bytes: size)
      assert text =~ "#{size}-byte limit"
      assert text =~ "start a new session"
      assert File.read!(file.path) == before
    end

    test "a last entry without its newline counts with the newline", %{tmp_dir: dir} do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
      header = String.trim_trailing(File.read!(file.path), "\n")
      File.write!(file.path, header)

      assert {:error, {:too_large, _}} =
               SessionFile.resume(dir, "/repo", max_bytes: byte_size(header))

      assert File.read!(file.path) == header

      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_bytes: byte_size(header) + 1)
      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_bytes: byte_size(header) + 1)
    end

    test "the default limit is 64 MiB", %{tmp_dir: dir} do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
      # A sparse file: 64 MiB + 1 byte of size, no data blocks written.
      File.open!(file.path, [:read, :write, :binary], fn io ->
        {:ok, _} = :file.position(io, 64 * 1024 * 1024)
        :ok = IO.binwrite(io, "\n")
      end)

      assert {:error, {:too_large, text}} = SessionFile.resume(dir, "/repo")
      assert text =~ "67108864-byte limit"
    end
  end

  test "a file of many short lines is not split into a list of all of them", %{tmp_dir: dir} do
    {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
    File.write!(file.path, String.duplicate("\n", 4 * 1024 * 1024), [:append])

    # 4 MiB of empty lines as a list is over 100 MiB of heap. The file
    # binary itself is off-heap. The process dies if its heap passes 16 MiB.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: div(16 * 1024 * 1024, 8), kill: true})
        exit({:result, SessionFile.resume(dir, "/repo")})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:result, {:error, {:invalid_file, text}}}},
                   5_000

    assert text == "unparsable line 2"
  end

  describe "the heap cap of the decode" do
    test "a file whose decode passes the cap is rejected and not mutated", %{tmp_dir: dir} do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
      SessionFile.append_message(file, Message.user("hi"))
      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_heap_bytes: 16 * 1024 * 1024)

      # 1 MiB of `[` with a torn last line: the decode of deep nesting takes
      # tens of bytes of heap per file byte. The torn tail would be repaired
      # on an accepted file; here it must stay.
      File.write!(file.path, String.duplicate("[", 1024 * 1024), [:append])
      before = File.read!(file.path)

      assert {:error, {:too_large, text}} =
               SessionFile.resume(dir, "/repo", max_heap_bytes: 16 * 1024 * 1024)

      assert text =~ "#{16 * 1024 * 1024} bytes of memory"
      assert text =~ "start a new session"
      assert File.read!(file.path) == before
    end

    test "a text-heavy session near the file limit fits the default cap", %{tmp_dir: dir} do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")

      file =
        SessionFile.append_message(file, Message.user(String.duplicate("line of output\n", 4000)))

      [_header, line] = String.split(File.read!(file.path), "\n", trim: true)
      count = div(63 * 1024 * 1024, byte_size(line) + 1)
      File.write!(file.path, String.duplicate(line <> "\n", count - 1), [:append])

      assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
      assert length(resumed.messages) == count
    end

    test "the caller's heap does not hold the decode", %{tmp_dir: dir} do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
      File.write!(file.path, String.duplicate("[", 1024 * 1024) <> "\n", [:append])

      # The caller dies if its heap passes 16 MiB; the decode alone needs more.
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: div(16 * 1024 * 1024, 8), kill: true})
          exit({:result, SessionFile.resume(dir, "/repo")})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:result, result}}, 10_000
      assert {:error, {:invalid_file, "unparsable line 2"}} = result
    end
  end

  test "a limit that is not a positive integer raises; the file is not blamed", %{tmp_dir: dir} do
    {:ok, _file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")

    for bad <- [0, -1, 1.5, nil, 64 * 1024 * 1024 + 1] do
      assert_raise FunctionClauseError, fn -> SessionFile.resume(dir, "/repo", max_bytes: bad) end
    end

    for bad <- [0, -1, 1.5, nil, 8, 1024 * 1024 - 1, 1024 * 1024 * 1024 + 1] do
      assert_raise FunctionClauseError, fn ->
        SessionFile.resume(dir, "/repo", max_heap_bytes: bad)
      end
    end

    for good <- [1024 * 1024, 1024 * 1024 * 1024] do
      assert {:ok, _} = SessionFile.resume(dir, "/repo", max_heap_bytes: good)
    end

    for bad <- [0, -1, 1.5, nil, 257] do
      assert_raise FunctionClauseError, fn ->
        SessionFile.resume(dir, "/repo", max_scanned_files: bad)
      end
    end
  end

  describe "the header scan" do
    # The header line of a session whose model pads the line to `bytes`.
    defp header_of(bytes, pad) do
      base = ~s({"type":"session","version":1,"cwd":"/repo","id":"h","ts":"t","model":")
      count = div(bytes - byte_size(base) - 2, byte_size(pad))
      line = base <> String.duplicate(pad, count) <> ~s("})
      line <> String.duplicate(" ", bytes - byte_size(line))
    end

    defp overwrite_session(dir, header) do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
      File.write!(file.path, header <> "\n")
    end

    test "a header line of 65,536 bytes is found, also with multibyte text", %{tmp_dir: dir} do
      overwrite_session(dir, header_of(65_536, "é"))
      assert {:ok, _} = SessionFile.resume(dir, "/repo")

      overwrite_session(dir, header_of(65_535, "a"))
      assert {:ok, _} = SessionFile.resume(dir, "/repo")
    end

    test "a header line one byte over is not a session", %{tmp_dir: dir} do
      overwrite_session(dir, header_of(65_537, "a"))
      assert {:error, :not_found} = SessionFile.resume(dir, "/repo")
    end

    test "a file that is not regular is skipped, not opened", %{tmp_dir: dir} do
      {:ok, file} = SessionFile.create(dir, "sess1", "/repo", "test/ok")
      {_, 0} = System.cmd("mkfifo", [Path.join(Path.dirname(file.path), "pipe.jsonl")])

      assert {:ok, resumed} = SessionFile.resume(dir, "/repo")
      assert resumed.session_id == "sess1"
    end
  end

  describe "the file count of the header scan" do
    # "_repo" has the slug of "/repo", so its sessions share the directory.
    defp session_at(dir, id, cwd, mtime) do
      {:ok, file} = SessionFile.create(dir, id, cwd, "test/ok")
      File.touch!(file.path, mtime)
      file
    end

    test "a session older than the newest files is not found", %{tmp_dir: dir} do
      session_at(dir, "old", "/repo", 1_000)
      session_at(dir, "b", "_repo", 2_000)
      session_at(dir, "c", "_repo", 3_000)

      assert {:error, :not_found} = SessionFile.resume(dir, "/repo", max_scanned_files: 2)
      assert {:ok, resumed} = SessionFile.resume(dir, "/repo", max_scanned_files: 3)
      assert resumed.session_id == "old"
    end

    test "the modification time selects the files, then the start time decides",
         %{tmp_dir: dir} do
      # The sleeps put the start times of the headers in order.
      session_at(dir, "first", "/repo", 3_000)
      Process.sleep(2)
      session_at(dir, "second", "/repo", 1_000)
      Process.sleep(2)
      session_at(dir, "third", "/repo", 2_000)

      assert {:ok, %{session_id: "first"}} =
               SessionFile.resume(dir, "/repo", max_scanned_files: 1)

      assert {:ok, %{session_id: "third"}} = SessionFile.resume(dir, "/repo")
    end

    test "a file that is not regular does not count", %{tmp_dir: dir} do
      file = session_at(dir, "sess1", "/repo", 1_000)
      {_, 0} = System.cmd("mkfifo", [Path.join(Path.dirname(file.path), "pipe.jsonl")])

      assert {:ok, %{session_id: "sess1"}} =
               SessionFile.resume(dir, "/repo", max_scanned_files: 1)
    end

    test "the default limit is 256 files", %{tmp_dir: dir} do
      session_at(dir, "old", "/repo", 1_000)
      for n <- 1..255, do: session_at(dir, "s#{n}", "_repo", 2_000 + n)
      assert {:ok, %{session_id: "old"}} = SessionFile.resume(dir, "/repo")

      session_at(dir, "s256", "_repo", 3_000)
      assert {:error, :not_found} = SessionFile.resume(dir, "/repo")
    end

    test "the path breaks a tie of the modification time", %{tmp_dir: dir} do
      session_at(dir, "a", "/repo", 1_000)
      session_at(dir, "b", "_repo", 1_000)

      assert {:error, :not_found} = SessionFile.resume(dir, "/repo", max_scanned_files: 1)
      assert {:ok, %{session_id: "b"}} = SessionFile.resume(dir, "_repo", max_scanned_files: 1)
    end
  end

  test "a working directory that is not UTF-8 is an error, not a raise", %{tmp_dir: dir} do
    assert {:error, {:create_failed, _}} =
             SessionFile.create(dir, "sess1", <<"/repo", 255>>, "test/ok")
  end
end
