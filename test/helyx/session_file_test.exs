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

  test "a working directory that is not UTF-8 is an error, not a raise", %{tmp_dir: dir} do
    assert {:error, {:create_failed, _}} =
             SessionFile.create(dir, "sess1", <<"/repo", 255>>, "test/ok")
  end
end
