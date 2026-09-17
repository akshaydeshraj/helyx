defmodule Helyx.ToolTest do
  use ExUnit.Case, async: true

  alias Helyx.Tool

  test "short text is returned as is" do
    assert Tool.truncate("a\nb", :head) == "a\nb"
    assert Tool.truncate("a\nb", :tail) == "a\nb"
  end

  test "head keeps the first 2000 lines and says what it shows" do
    text = Enum.map_join(1..2500, "\n", &to_string/1)
    out = Tool.truncate(text, :head)
    assert String.starts_with?(out, "1\n2\n")
    assert String.ends_with?(out, "\n2000\n[truncated: showing lines 1-2000 of 2500]")
  end

  test "tail keeps the last 2000 lines and says what it shows" do
    text = Enum.map_join(1..2500, "\n", &to_string/1)
    out = Tool.truncate(text, :tail)
    assert String.starts_with?(out, "[truncated: showing lines 501-2500 of 2500]\n501\n")
    assert String.ends_with?(out, "\n2500")
  end

  test "the byte limit cuts on a whole line" do
    text = Enum.map_join(1..100, "\n", fn _ -> String.duplicate("x", 1000) end)
    out = Tool.truncate(text, :head)
    assert String.ends_with?(out, "[truncated: showing lines 1-51 of 100]")
    assert byte_size(out) <= 51_200 + 60
  end

  test "a trailing newline does not count as a line" do
    text = Enum.map_join(1..2500, "\n", &to_string/1) <> "\n"

    assert String.ends_with?(
             Tool.truncate(text, :head),
             "[truncated: showing lines 1-2000 of 2500]"
           )
  end

  test "a first line over the byte limit is cut to the limit" do
    big = String.duplicate("x", 60_000)
    head = Tool.truncate(big <> "\nb", :head)
    assert String.ends_with?(head, "\n[truncated: showing lines 1-1 of 2]")
    assert byte_size(head) < 51_300

    tail = Tool.truncate("a\n" <> big, :tail)
    assert String.starts_with?(tail, "[truncated: showing lines 2-2 of 2]\n")
    assert byte_size(tail) < 51_300
  end
end
