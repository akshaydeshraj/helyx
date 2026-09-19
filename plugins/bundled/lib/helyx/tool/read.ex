defmodule Helyx.Tool.Read do
  @moduledoc """
  Reads a file. Long files keep the head, and the result says which absolute
  lines it shows and, when lines follow them, which offset continues the
  read; `offset` reads from a later line.

  An `offset` that is not a positive integer is an error, never a silent
  default. A float with no fraction, such as `2001.0`, is its integer. A
  missing or null `offset` is line 1.
  """

  @behaviour Helyx.Tool

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a file. Returns at most 2000 lines or 50 KB, starting at offset " <>
      "(a 1-based line number, default 1); a truncated result names the " <>
      "offset that continues the read, when lines follow."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path, absolute or relative to the working directory"
        },
        "offset" => %{"type" => "integer", "description" => "First line to return, 1-based"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def run(%{"path" => path} = args, cwd) when is_binary(path) do
    with {:ok, offset} <- offset(args["offset"]) do
      case Helyx.Tool.read_file(Path.expand(path, cwd)) do
        {:ok, content} -> {:ok, Helyx.Tool.truncate(content, :head, offset)}
        {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
      end
    end
  end

  def run(_args, _cwd), do: {:error, "read needs a path"}

  defp offset(nil), do: {:ok, 1}
  defp offset(n) when is_integer(n) and n > 0, do: {:ok, n}
  # The JSON encoders of some models send `2001.0` for 2001 (#75).
  defp offset(f) when is_float(f) and f >= 1.0 and trunc(f) == f, do: {:ok, trunc(f)}

  defp offset(other) do
    {:error, "offset must be a positive integer (a 1-based line number), got #{kind(other)}"}
  end

  # The error names the kind of the value and never shows the value, so its
  # size and its cost do not depend on the argument.
  defp kind(n) when is_integer(n), do: "an integer below 1"
  defp kind(f) when is_float(f), do: "a number that is not a whole number of 1 or more"
  defp kind(s) when is_binary(s), do: "a string"
  defp kind(b) when is_boolean(b), do: "a boolean"
  defp kind(l) when is_list(l), do: "an array"
  defp kind(_other), do: "an object"
end
