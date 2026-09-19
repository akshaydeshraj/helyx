defmodule Helyx.Tool do
  @moduledoc """
  A tool the model can call. The hands run it in the session's working
  directory.

  A tool plugin implements this behaviour. `name/0` is what the model calls.
  `parameters/0` is a JSON schema map with string keys. `run/2` gets the
  decoded argument map and the working directory, and returns the text the
  model sees. `{:error, text}` marks the result as an error; a tool that
  raises is reported the same way.

  The optional `check/0` runs when the hands start. A tool that needs
  something from the system, an executable for example, reports it missing
  there, so the session fails to start with a clear error instead of every
  call failing later.
  """

  use Helyx.Interface, mode: :multi

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(arguments :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback check() :: :ok | {:error, String.t()}

  @optional_callbacks check: 0

  @max_lines 2000
  @max_bytes 51_200
  @max_file_bytes 10_485_760

  @doc "Returns the registered tool plugins by name. Two tools with one name is an error."
  @spec by_name(Helyx.Core.name()) ::
          {:ok, %{String.t() => module()}} | {:error, {:duplicate_tool_name, String.t()}}
  def by_name(core) do
    tools = Helyx.Core.plugins(core, __MODULE__)

    case tools -- Enum.uniq_by(tools, & &1.name()) do
      [] -> {:ok, Map.new(tools, &{&1.name(), &1})}
      [dup | _] -> {:error, {:duplicate_tool_name, dup.name()}}
    end
  end

  @doc "Returns the spec of a tool plugin, as plain terms."
  @spec spec(module()) :: spec()
  def spec(tool) do
    %{name: tool.name(), description: tool.description(), parameters: tool.parameters()}
  end

  @doc "The byte limit of `truncate/2` and `truncate/3`."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Registers an OS process group the tool call started with the hands that
  run it. A call can register several groups; the hands hold them per Task
  and kill every one when the call delivers or the turn is aborted, so no
  group outlives the Task that started it. A group registered as
  `:watchdog` is a reaper: the hands sweep it only after every `:command`
  group swept with it is gone or stuck, and give it time to exit by itself
  first, so a KILL from the hands can never leave a command unreaped. A no-op when
  the tool runs outside the hands. Groups below 2 are rejected: `kill -- -1`
  would signal every process the user may signal.
  """
  @spec register_group(pos_integer(), :command | :watchdog) :: :ok
  def register_group(group, kind \\ :command)
      when is_integer(group) and group > 1 and kind in [:command, :watchdog] do
    case Process.get(:helyx_hands) do
      nil -> :ok
      hands -> GenServer.call(hands, {:register_group, group, kind}, :infinity)
    end
  end

  @doc """
  Reads a regular file of at most #{@max_file_bytes} bytes, whole. A device,
  a directory, a larger file, or a file that is not valid UTF-8 is an error,
  so a tool never loads unbounded input and never returns text a later
  encoder cannot handle. The read itself is bounded, so a file that grows
  after the check is still an error. The error is a short reason without
  the path.
  """
  @spec read_file(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_file(full) do
    case File.stat(full) do
      {:ok, %File.Stat{type: :regular}} -> read_bounded(full)
      {:ok, %File.Stat{type: type}} -> {:error, "not a regular file (#{type})"}
      {:error, reason} -> {:error, to_string(:file.format_error(reason))}
    end
  end

  defp read_bounded(full) do
    case File.open(full, [:read, :binary]) do
      {:ok, io} ->
        data = IO.binread(io, @max_file_bytes + 1)
        :ok = File.close(io)
        bounded(data)

      {:error, _} = error ->
        bounded(error)
    end
  end

  defp bounded(:eof), do: {:ok, ""}
  defp bounded({:error, reason}), do: {:error, to_string(:file.format_error(reason))}

  defp bounded(bin) when byte_size(bin) > @max_file_bytes,
    do: {:error, "over the #{@max_file_bytes}-byte limit"}

  defp bounded(bin) do
    if String.valid?(bin), do: {:ok, bin}, else: {:error, "binary file, #{byte_size(bin)} bytes"}
  end

  @doc """
  Caps text at #{@max_lines} lines or #{@max_bytes} bytes of line content,
  on whole lines. One trailing newline is a terminator and does not count.
  `:head` keeps the start and `:tail` keeps the end. A truncated result says
  which lines it shows; a truncated `:head` result also names the offset that
  continues the read, unless the cut line is the last line. When the line at
  the kept edge is over the byte cap by itself, it is cut to the cap and is
  the only line shown; the notice names that line and the bytes kept of it,
  and no offset reaches the rest.
  """
  @spec truncate(String.t(), :head | :tail) :: String.t()
  def truncate(text, :head), do: truncate(text, :head, 1)

  def truncate(text, :tail) do
    lines = lines(text)
    total = length(lines)

    case take_within_limits(Enum.reverse(lines), :tail) do
      :all ->
        text

      {kept, n, cut_bytes} ->
        "[truncated: showing lines #{total - n + 1}-#{total} of #{total}#{cut_note(cut_bytes, total)}]\n" <>
          Enum.join(Enum.reverse(kept), "\n")
    end
  end

  @doc """
  Like `truncate/2` with `:head`, starting at line `first`: earlier lines are
  dropped before the caps apply. A truncated result names the absolute line
  numbers it shows and, when lines follow them, the offset that continues
  the read. A window that starts past line 1 is rebuilt from its lines, so it
  carries no trailing newline.
  """
  @spec truncate(String.t(), :head, pos_integer()) :: String.t()
  def truncate(text, :head, first) do
    shown = Enum.drop(lines(text), first - 1)

    case take_within_limits(shown, :head) do
      :all when first == 1 ->
        text

      :all ->
        Enum.join(shown, "\n")

      {kept, n, cut_bytes} ->
        last = first + n - 1
        total = first - 1 + length(shown)

        Enum.join(kept, "\n") <>
          "\n[truncated: showing lines #{first}-#{last} of #{total}" <>
          "#{cut_note(cut_bytes, first)}#{offset_note(last, total)}]"
    end
  end

  # Only a cut last line is truncated with no line after it; an offset past
  # it returns nothing, so the notice names none.
  defp offset_note(total, total), do: ""
  defp offset_note(last, _total), do: "; read again with offset #{last + 1}"

  # The cut line is always the one at the kept edge: the first line of a
  # head window, the last line of a tail.
  defp cut_note(nil, _line_number), do: ""
  defp cut_note(bytes, line_number), do: ", line #{line_number} cut at #{bytes} bytes"

  # One trailing newline ends the last line; more are blank lines that count.
  defp lines(text), do: text |> String.replace_suffix("\n", "") |> String.split("\n")

  # Returns `:all` when every line fits, else the lines within the limits in
  # the given order, their count, and `nil`. A first line over the byte limit
  # is cut to the limit on a character boundary, from the end kept; the third
  # element is then the bytes shown of it.
  defp take_within_limits([first | _], keep) when byte_size(first) > @max_bytes do
    shown = cut(first, keep)
    {[shown], 1, byte_size(shown)}
  end

  defp take_within_limits(lines, _keep) do
    {count, _bytes, acc} =
      Enum.reduce_while(lines, {0, 0, []}, fn line, {count, bytes, acc} ->
        if count < @max_lines and bytes + byte_size(line) <= @max_bytes,
          do: {:cont, {count + 1, bytes + byte_size(line) + 1, [line | acc]}},
          else: {:halt, {count, bytes, acc}}
      end)

    if count == length(lines), do: :all, else: {Enum.reverse(acc), count, nil}
  end

  # A UTF-8 character is at most 4 bytes, so a cut leaves at most 3 bytes of
  # one at the cut edge.
  @max_partial_bytes 3

  defp cut(line, :head), do: line |> binary_part(0, @max_bytes) |> clean_edge(:head)

  defp cut(line, :tail),
    do: line |> binary_part(byte_size(line) - @max_bytes, @max_bytes) |> clean_edge(:tail)

  # In text that was valid before the cut, the only invalid bytes are the
  # part of a character at the cut edge, so removing them loses one
  # character. Invalid bytes anywhere else mean the text was never valid: it
  # keeps its bytes for the hands to replace, less three at the edge.
  defp clean_edge(bin, keep) do
    clean = String.replace_invalid(bin, "")
    lost = byte_size(bin) - byte_size(clean)

    if lost <= @max_partial_bytes and clean == without_edge(bin, keep, lost),
      do: clean,
      else: without_edge(bin, keep, @max_partial_bytes)
  end

  defp without_edge(bin, :head, n), do: binary_part(bin, 0, byte_size(bin) - n)
  defp without_edge(bin, :tail, n), do: binary_part(bin, n, byte_size(bin) - n)
end
