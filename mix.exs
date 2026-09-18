defmodule Helyx.MixProject do
  use Mix.Project

  def project do
    [
      app: :helyx,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.2", only: [:dev, :test]}
    ]
  end

  defp aliases do
    # Credo covers plugin and app sources from the root via .credo.exs.
    # Dialyzer cannot: they depend on the root, not the reverse, so each
    # project's precommit runs its own, with a forced PLT check because a path
    # dependency never changes the lock file that triggers one.
    # No glob and no command string: a glob character in the checkout path or a
    # quote in a directory name made earlier forms pass while skipping a project.
    projects =
      for parent <- ["plugins", "apps"],
          root = Path.join(__DIR__, parent),
          File.dir?(root),
          name <- Enum.sort(File.ls!(root)),
          dir = Path.join(root, name),
          File.regular?(Path.join(dir, "mix.exs")) do
        fn _ ->
          # A child that inherits MIX_EXS loads this project again and recurses.
          System.delete_env("MIX_EXS")
          Mix.Task.run("cmd", ["--cd", dir, "mix", "precommit"])
        end
      end

    [
      precommit:
        ["format", "compile --warnings-as-errors", "credo --strict", "dialyzer", "test"] ++
          projects
    ]
  end
end
