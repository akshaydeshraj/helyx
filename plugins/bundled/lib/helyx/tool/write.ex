defmodule Helyx.Tool.Write do
  @moduledoc "Writes a file, creating parent directories. An existing file is replaced."

  @behaviour Helyx.Tool

  @impl true
  def name, do: "write"

  @impl true
  def description,
    do:
      "Write content to a file. Creates the file and its directories; replaces an existing file."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path, absolute or relative to the working directory"
        },
        "content" => %{"type" => "string"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def run(%{"path" => path, "content" => content}, cwd)
      when is_binary(path) and is_binary(content) do
    full = Path.expand(path, cwd)

    with :ok <- File.mkdir_p(Path.dirname(full)),
         :ok <- File.write(full, content) do
      {:ok, "Wrote #{path}"}
    else
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  def run(_args, _cwd), do: {:error, "write needs a path and content"}
end
