defmodule Helyx.Tool.Edit do
  @moduledoc """
  Replaces one exact occurrence of text in a file. The search text must
  appear exactly once; zero or several matches is an error and the file is
  untouched.
  """

  @behaviour Helyx.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Replace old_text with new_text in a file. old_text must match exactly once, " <>
      "so include enough surrounding lines to make it unique."
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
        "old_text" => %{"type" => "string", "description" => "Exact text to replace"},
        "new_text" => %{"type" => "string", "description" => "Replacement text"}
      },
      "required" => ["path", "old_text", "new_text"]
    }
  end

  @impl true
  def run(%{"path" => path, "old_text" => old, "new_text" => new}, cwd)
      when is_binary(path) and is_binary(old) and is_binary(new) do
    full = Path.expand(path, cwd)

    with {:ok, content} <- read(full, path),
         {:ok, edited} <- replace_once(content, old, new, path),
         :ok <- write(full, edited, path) do
      {:ok, "Edited #{path}"}
    end
  end

  def run(_args, _cwd), do: {:error, "edit needs a path, old_text, and new_text"}

  defp replace_once(_content, "", _new, _path), do: {:error, "old_text is empty"}

  defp replace_once(content, old, new, path) do
    case String.split(content, old) do
      [before, rest] -> {:ok, before <> new <> rest}
      [_] -> {:error, "old_text not found in #{path}"}
      parts -> {:error, "old_text matches #{length(parts) - 1} places in #{path}; make it unique"}
    end
  end

  defp read(full, path) do
    with {:error, reason} <- File.read(full) do
      {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write(full, content, path) do
    with {:error, reason} <- File.write(full, content) do
      {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
