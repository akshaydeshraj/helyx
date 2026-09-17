defmodule Helyx.ModelContext.Default do
  @moduledoc """
  The default model context: a base prompt plus every `AGENTS.md` found from
  the home directory down to the working directory, in that order.

  Each file follows a heading with its path. A level without an `AGENTS.md`,
  or with one that `Helyx.Tool.read_file/1` rejects, is skipped without
  error. A working directory outside the home directory
  contributes only its own `AGENTS.md`. `opts` can carry `:home` to override
  the home directory, for tests.
  """

  @behaviour Helyx.ModelContext

  @base_prompt "You are a coding agent. You work in the user's repository with the tools provided."

  @impl true
  def build(context, opts) do
    cwd = Path.expand(Keyword.fetch!(opts, :cwd))
    home = Path.expand(opts[:home] || System.user_home!())

    sections =
      for dir <- chain(cwd, home),
          path = Path.join(dir, "AGENTS.md"),
          {:ok, content} <- [Helyx.Tool.read_file(path)],
          do: "## #{path}\n\n#{content}"

    %{context | system: Enum.join([@base_prompt | sections], "\n\n")}
  end

  # The directories from home down to cwd, both included. A cwd outside home
  # has no such path, so it contributes alone.
  defp chain(cwd, home) do
    home_parts = Path.split(home)
    cwd_parts = Path.split(cwd)

    if List.starts_with?(cwd_parts, home_parts) do
      below = Enum.drop(cwd_parts, length(home_parts))
      [home | Enum.scan(below, home, &Path.join(&2, &1))]
    else
      [cwd]
    end
  end
end
