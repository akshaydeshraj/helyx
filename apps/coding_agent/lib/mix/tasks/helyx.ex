defmodule Mix.Tasks.Helyx do
  @default_model "opencode-go/kimi-k2"

  @shortdoc "Starts the coding agent TUI"
  @moduledoc """
  Starts the coding agent in the alternate screen.

      mix helyx [directory] [--model provider/model] [--resume]

  `directory` is the session's working directory and defaults to the current
  one. `--model` defaults to `#{@default_model}`, which needs
  `OPENCODE_API_KEY`. `fake/echo` runs without a key.

  Sessions are written under `~/.helyx/sessions` as they run. `--resume`
  continues the most recent session for the directory and keeps its saved
  model, so it does not combine with `--model`.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, args} =
      try do
        OptionParser.parse!(argv, strict: [model: :string, resume: :boolean])
      rescue
        error in OptionParser.ParseError -> Mix.raise(Exception.message(error))
      end

    if opts[:resume] && opts[:model] do
      Mix.raise("--model does not combine with --resume; a resumed session keeps its saved model")
    end

    cwd =
      case args do
        [] -> File.cwd!()
        [directory] -> Path.expand(directory)
        _ -> Mix.raise("expected at most one directory argument, got: #{Enum.join(args, " ")}")
      end

    if not File.dir?(cwd), do: Mix.raise("not a directory: #{cwd}")

    Mix.Task.run("app.start")

    result =
      CodingAgent.run(
        model: Keyword.get(opts, :model, @default_model),
        cwd: cwd,
        resume: Keyword.get(opts, :resume, false),
        # Application env so that a test points the task at its own directory.
        sessions_dir: Application.get_env(:coding_agent, :sessions_dir)
      )

    with {:error, reason} <- result do
      Mix.raise("could not start the agent: #{CodingAgent.error_text(reason)}")
    end
  end
end
