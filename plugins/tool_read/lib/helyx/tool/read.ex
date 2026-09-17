defmodule Helyx.Tool.Read do
  @moduledoc """
  Reads a file. Long files are cut from the tail end and the result says
  which lines it shows; `offset` reads from a later line.
  """

  @behaviour Helyx.Tool

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a file. Returns at most 2000 lines or 50 KB from the start; " <>
      "pass offset (a 1-based line number) to read further."
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
      {:ok, content} -> {:ok, content |> from_line(offset) |> Helyx.Tool.truncate(:head)}
      {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
    end
  end

  def run(_args, _cwd), do: {:error, "read needs a path"}

  defp from_line(content, offset) when is_integer(offset) and offset > 1 do
    content |> String.split("\n") |> Enum.drop(offset - 1) |> Enum.join("\n")
  end

  defp from_line(content, _offset), do: content
end
