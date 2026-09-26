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
    {opts, args} = parse(argv)

    if opts[:resume] && opts[:model] do
      Mix.raise("--model does not combine with --resume; a resumed session keeps its saved model")
    end

    cwd =
      case args do
        [] -> File.cwd!()
        [directory] -> Path.expand(directory)
        _ -> Mix.raise("expected at most one directory argument, got: #{inspect(args)}")
      end

    if not File.dir?(cwd), do: Mix.raise("not a directory: #{inspect(cwd)}")

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

  # The command line is a boundary: every argument in an error shows through
  # inspect/1. OptionParser raises on some arguments that are not UTF-8, so
  # they stop here, and parse!/2 would put the raw switch name in its error.
  defp parse(argv) do
    if bad = Enum.find(argv, &(not String.valid?(&1))) do
      Mix.raise("an argument is not UTF-8: #{inspect(bad, binaries: :as_strings)}")
    end

    case OptionParser.parse(argv, strict: [model: :string, resume: :boolean]) do
      {opts, args, []} ->
        {opts, args}

      {_, _, invalid} ->
        Mix.raise(
          "unknown option or bad value: #{Enum.map_join(invalid, ", ", &option_text/1)}; " <>
            "the options are --model provider/model and --resume"
        )
    end
  end

  defp option_text({name, nil}), do: inspect(name)
  defp option_text({name, value}), do: "#{inspect(name)}=#{inspect(value)}"
end
