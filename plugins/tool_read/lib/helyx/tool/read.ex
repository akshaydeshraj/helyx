defmodule Helyx.Tool.Read do
  @moduledoc """
  Reads a file. Long files keep the head, and the result says which absolute
  lines it shows and which offset continues the read; `offset` reads from a
  later line.
  """

  @behaviour Helyx.Tool

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a file. Returns at most 2000 lines or 50 KB, starting at offset " <>
      "(a 1-based line number, default 1); a truncated result names the " <>
      "offset that continues the read."
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
    offset = Map.get(args, "offset", 1)
    full = Path.expand(path, cwd)

    case Helyx.Tool.read_file(full) do
      {:ok, content} -> {:ok, window(content, offset)}
      {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
    end
  end

  def run(_args, _cwd), do: {:error, "read needs a path"}

  defp window(content, offset) when is_integer(offset) and offset > 1 do
    Helyx.Tool.truncate(content, :head, offset)
  end

  defp window(content, _offset), do: Helyx.Tool.truncate(content, :head)
end
