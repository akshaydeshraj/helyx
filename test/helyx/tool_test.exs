defmodule Helyx.ToolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helyx.Tool

  # The limits of truncate/2, stated independently of the code under test.
  @max_lines 2000
  @max_bytes 51_200

  property "truncate/2 stays valid UTF-8, within the limits, and on whole lines" do
    check all(text <- text(), keep <- member_of([:head, :tail])) do
      out = Tool.truncate(text, keep)
      assert String.valid?(out)

      stripped = String.replace_suffix(text, "\n", "")
      input_lines = String.split(stripped, "\n")
      total = length(input_lines)

      # The exact fit condition: line content plus separators, without the
      # one trailing newline that acts as a terminator.
      fits = total <= @max_lines and byte_size(stripped) <= @max_bytes

      # Unchanged output within the limits is the untruncated case. Any other
      # output must carry a well-formed notice that matches a kept slice of
      # the input. Equality alone cannot decide the branch: when the edge
      # line is exactly the notice truncate emits, a truncated output equals
      # its over-limit input.
      if out != text or not fits do
        assert {first, last, ^total, content} = notice(out, keep)
        kept = last - first + 1
        assert kept in 1..@max_lines
        assert byte_size(content) <= @max_bytes
        if keep == :head, do: assert(first == 1), else: assert(last == total)

        slice = Enum.slice(input_lines, first - 1, kept)

        if kept == 1 and byte_size(hd(slice)) > @max_bytes do
          edge = if keep == :head, do: &String.starts_with?/2, else: &String.ends_with?/2
          assert edge.(hd(slice), content)
        else
          assert String.split(content, "\n") == slice
        end
      end
    end
  end

  # Every limit is crossed from both sides: small samples carry a line over
  # the byte limit, big samples cross the line limit and, through the medium
  # lines, the byte total. The giant line stays out of the big samples so a
  # sample never reaches megabytes.
  defp text do
    short = string(:printable, max_length: 40)
    medium = string(:printable, min_length: 300, max_length: 600)
    giant = map(short, &(String.duplicate("x", @max_bytes - 50) <> &1))

    small = list_of(frequency([{10, short}, {3, medium}, {1, giant}]), max_length: 50)

    big =
      list_of(frequency([{10, short}, {1, medium}]), length: (@max_lines - 10)..(@max_lines + 10))

    gen all(
          lines <- frequency([{2, small}, {1, big}]),
          suffix <- member_of(["", "\n", "\n\n\n"])
        ) do
      Enum.join(lines, "\n") <> suffix
    end
  end

  defp notice(out, :head) do
    assert [_, content, first, last, total] =
             Regex.run(~r/\A(.*)\n\[truncated: showing lines (\d+)-(\d+) of (\d+)\]\z/s, out)

    to_tuple(first, last, total, content)
  end

  defp notice(out, :tail) do
    assert [_, first, last, total, content] =
             Regex.run(~r/\A\[truncated: showing lines (\d+)-(\d+) of (\d+)\]\n(.*)\z/s, out)

    to_tuple(first, last, total, content)
  end

  defp to_tuple(first, last, total, content) do
    {String.to_integer(first), String.to_integer(last), String.to_integer(total), content}
  end

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

  test "trailing blank lines count toward the limits" do
    out = Tool.truncate("a" <> String.duplicate("\n", 60_000), :head)
    assert String.ends_with?(out, "[truncated: showing lines 1-2000 of 60000]")
  end

  test "a cut line stays valid UTF-8" do
    line = String.duplicate("€", 20_000)

    for keep <- [:head, :tail] do
      out = Tool.truncate(line, keep)
      assert String.valid?(out)
      assert out =~ "showing lines 1-1 of 1"
    end
  end

  test "an input whose last line is exactly the notice is a truncation fixed point" do
    text = String.duplicate("a\n", 2000) <> "[truncated: showing lines 1-2000 of 2001]"
    assert Tool.truncate(text, :head) == text
  end

  test "a line exactly at the byte limit is kept" do
    line = String.duplicate("x", 51_200)
    assert Tool.truncate(line, :head) == line
    assert Tool.truncate(line, :tail) == line

    assert String.starts_with?(
             Tool.truncate(line <> "\nb", :head),
             line <> "\n[truncated: showing lines 1-1 of 2]"
           )
  end
end
