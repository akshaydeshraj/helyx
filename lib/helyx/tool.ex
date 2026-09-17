defmodule Helyx.Tool do
  @moduledoc """
  A tool the model can call. The hands run it in the session's working
  directory.

  A tool plugin implements this behaviour. `name/0` is what the model calls.
  `parameters/0` is a JSON schema map with string keys. `run/2` gets the
  decoded argument map and the working directory, and returns the text the
  model sees. `{:error, text}` marks the result as an error; a tool that
  raises is reported the same way.
  """

  use Helyx.Interface, mode: :multi

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(arguments :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @max_lines 2000
  @max_bytes 51_200

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

  @doc """
  Caps text at #{@max_lines} lines or #{@max_bytes} bytes, on whole lines.
  `:head` keeps the start and `:tail` keeps the end. A truncated result says
  which lines it shows.
  """
  @spec truncate(String.t(), :head | :tail) :: String.t()
  def truncate(text, :head) do
    lines = lines(text)

    case take_within_limits(lines, :head) do
      :all ->
        text

      {kept, n} ->
        Enum.join(kept, "\n") <> "\n[truncated: showing lines 1-#{n} of #{length(lines)}]"
    end
  end

  def truncate(text, :tail) do
    lines = lines(text)
    total = length(lines)

    case take_within_limits(Enum.reverse(lines), :tail) do
      :all ->
        text

      {kept, n} ->
        "[truncated: showing lines #{total - n + 1}-#{total} of #{total}]\n" <>
          Enum.join(Enum.reverse(kept), "\n")
    end
  end

  defp lines(text), do: text |> String.trim_trailing("\n") |> String.split("\n")

  # Returns `:all` when every line fits, else the lines within the limits in
  # the given order and their count. A first line over the byte limit is cut
  # to the limit, from the end kept.
  defp take_within_limits([first | _], keep) when byte_size(first) > @max_bytes do
    start = if keep == :head, do: 0, else: byte_size(first) - @max_bytes
    {[binary_part(first, start, @max_bytes)], 1}
  end

  defp take_within_limits(lines, _keep) do
    {count, _bytes, acc} =
      Enum.reduce_while(lines, {0, 0, []}, fn line, {count, bytes, acc} ->
        bytes = bytes + byte_size(line) + 1

        if count < @max_lines and bytes <= @max_bytes,
          do: {:cont, {count + 1, bytes, [line | acc]}},
          else: {:halt, {count, bytes, acc}}
      end)

    if count == length(lines), do: :all, else: {Enum.reverse(acc), count}
  end
end
