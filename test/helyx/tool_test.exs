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
        assert {first, last, ^total, content, note} = notice(out, keep)
        kept = last - first + 1
        assert kept in 1..@max_lines
        assert byte_size(content) <= @max_bytes
        if keep == :head, do: assert(first == 1), else: assert(last == total)

        slice = Enum.slice(input_lines, first - 1, kept)

        # The note is there exactly when the line was cut, and it names that
        # line and the bytes shown of it.
        if kept == 1 and byte_size(hd(slice)) > @max_bytes do
          edge = if keep == :head, do: &String.starts_with?/2, else: &String.ends_with?/2
          assert edge.(hd(slice), content)
          assert note == ", line #{first} cut at #{byte_size(content)} bytes"
        else
          assert String.split(content, "\n") == slice
          assert note == ""
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
    assert [_, content, first, last, total, note, offset] =
             Regex.run(
               ~r/\A(.*)\n\[truncated: showing lines (\d+)-(\d+) of (\d+)(, line \d+ cut at \d+ bytes)?; read again with offset (\d+)\]\z/s,
               out
             )

    assert String.to_integer(offset) == String.to_integer(last) + 1
    to_tuple(first, last, total, content, note)
  end

  defp notice(out, :tail) do
    assert [_, first, last, total, note, content] =
             Regex.run(
               ~r/\A\[truncated: showing lines (\d+)-(\d+) of (\d+)(, line \d+ cut at \d+ bytes)?\]\n(.*)\z/s,
               out
             )

    to_tuple(first, last, total, content, note)
  end

  # An optional group that did not match is "".
  defp to_tuple(first, last, total, content, note) do
    {String.to_integer(first), String.to_integer(last), String.to_integer(total), content, note}
  end

  @tag :tmp_dir
  test "read_file/1 rejects a file that is not valid UTF-8", %{tmp_dir: dir} do
    path = Path.join(dir, "raw.bin")
    File.write!(path, <<"a", 255, "b">>)
    assert Tool.read_file(path) == {:error, "binary file, 3 bytes"}
  end

  @tag :tmp_dir
  test "read_file/1 accepts multibyte UTF-8", %{tmp_dir: dir} do
    path = Path.join(dir, "multi.txt")
    File.write!(path, "héllo wörld €😀")
    assert Tool.read_file(path) == {:ok, "héllo wörld €😀"}
  end

  test "short text is returned as is" do
    assert Tool.truncate("a\nb", :head) == "a\nb"
    assert Tool.truncate("a\nb", :tail) == "a\nb"
  end

  test "head keeps the first 2000 lines and says what it shows" do
    text = Enum.map_join(1..2500, "\n", &to_string/1)
    out = Tool.truncate(text, :head)
    assert String.starts_with?(out, "1\n2\n")

    assert String.ends_with?(
             out,
             "\n2000\n[truncated: showing lines 1-2000 of 2500; read again with offset 2001]"
           )
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

    assert String.ends_with?(
             out,
             "[truncated: showing lines 1-51 of 100; read again with offset 52]"
           )

    assert byte_size(out) <= 51_200 + 60
  end

  test "a trailing newline does not count as a line" do
    text = Enum.map_join(1..2500, "\n", &to_string/1) <> "\n"

    assert String.ends_with?(
             Tool.truncate(text, :head),
             "[truncated: showing lines 1-2000 of 2500; read again with offset 2001]"
           )
  end

  test "a first line over the byte limit is cut to the limit" do
    big = String.duplicate("x", 60_000)
    head = Tool.truncate(big <> "\nb", :head)

    assert String.ends_with?(
             head,
             "\n[truncated: showing lines 1-1 of 2, line 1 cut at 51200 bytes; read again with offset 2]"
           )

    assert byte_size(head) < 51_300

    tail = Tool.truncate("a\n" <> big, :tail)

    assert String.starts_with?(
             tail,
             "[truncated: showing lines 2-2 of 2, line 2 cut at 51200 bytes]\n"
           )

    assert byte_size(tail) < 51_300
  end

  test "a cut line is named in the notice, at its absolute number (issue #50)" do
    first = String.duplicate("x", 51_500 - 11) <> "TAIL_MARKER"
    refute Tool.truncate(first <> "\nline2", :head) =~ "TAIL_MARKER"

    assert String.ends_with?(
             Tool.truncate("a\n" <> first <> "\nline2", :head, 2),
             "\n[truncated: showing lines 2-2 of 3, line 2 cut at 51200 bytes; read again with offset 3]"
           )

    # One byte over the cap is cut; at the cap is not (see the test below).
    assert Tool.truncate(String.duplicate("x", 51_201), :head) =~ "line 1 cut at 51200 bytes;"
    assert Tool.truncate(String.duplicate("x", 51_201), :tail) =~ "line 1 cut at 51200 bytes]"

    # The byte count is what is shown, after the part of a character at the cut edge is removed.
    euro = String.duplicate("€", 20_000)
    assert Tool.truncate(euro, :head) =~ "line 1 cut at 51198 bytes;"
    assert Tool.truncate(euro, :tail) =~ "line 1 cut at 51198 bytes]"
  end

  test "trailing blank lines count toward the limits" do
    out = Tool.truncate("a" <> String.duplicate("\n", 60_000), :head)

    assert String.ends_with?(
             out,
             "[truncated: showing lines 1-2000 of 60000; read again with offset 2001]"
           )
  end

  test "a cut line stays valid UTF-8" do
    line = String.duplicate("€", 20_000)

    for keep <- [:head, :tail] do
      out = Tool.truncate(line, keep)
      assert String.valid?(out)
      assert out =~ "showing lines 1-1 of 1"
    end
  end

  test "a cut on text that was never valid loses three bytes at the cut edge" do
    out = Tool.truncate(:binary.copy(<<255>>, 60_000), :head)

    assert [
             cut,
             "[truncated: showing lines 1-1 of 1, line 1 cut at 51197 bytes; read again with offset 2]"
           ] =
             String.split(out, "\n", parts: 2)

    assert cut == :binary.copy(<<255>>, 51_197)

    # The hands replace the invalid bytes at delivery; the replacement is
    # valid and grows the text by at most a factor of three.
    replaced = String.replace_invalid(out)
    assert String.valid?(replaced)
    assert byte_size(replaced) <= 3 * byte_size(out)
  end

  test "a cut inside a character loses only that character (issue #51)" do
    # The cut lands 1, 2, and 3 bytes inside a 4-byte character, and on its edge.
    for pad <- 0..3 do
      shown = String.duplicate("😀", div(51_200 - pad, 4))
      rest = String.duplicate("😀", 1000)
      note = "line 1 cut at #{byte_size(shown) + pad} bytes"

      x = String.duplicate("x", pad)

      assert [head, "[truncated:" <> head_note] =
               String.split(Tool.truncate(x <> shown <> rest, :head), "\n")

      assert head == x <> shown
      assert head_note =~ note

      assert ["[truncated:" <> tail_note, tail] =
               String.split(Tool.truncate(rest <> shown <> x, :tail), "\n")

      assert tail == shown <> x
      assert tail_note =~ note
    end
  end

  test "an invalid byte away from the cut edge is kept for the hands to replace" do
    line = "ab" <> <<255>> <> String.duplicate("€", 20_000)
    out = Tool.truncate(line, :head)
    # Never valid: three bytes less at the edge, as before, and the notice counts them.
    assert String.starts_with?(out, "ab" <> <<255>> <> "€")
    assert String.contains?(out, "line 1 cut at 51197 bytes;")
    assert [shown, _note] = String.split(out, "\n")
    assert byte_size(shown) == 51_197
  end

  test "an input whose last line is exactly the notice is a truncation fixed point" do
    text =
      String.duplicate("a\n", 2000) <>
        "[truncated: showing lines 1-2000 of 2001; read again with offset 2001]"

    assert Tool.truncate(text, :head) == text
  end

  test "a line exactly at the byte limit is kept" do
    line = String.duplicate("x", 51_200)
    assert Tool.truncate(line, :head) == line
    assert Tool.truncate(line, :tail) == line

    assert String.starts_with?(
             Tool.truncate(line <> "\nb", :head),
             line <> "\n[truncated: showing lines 1-1 of 2; read again with offset 2]"
           )
  end
end
