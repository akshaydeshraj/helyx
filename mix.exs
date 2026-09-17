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
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test",
        # Credo covers plugin sources from the root via .credo.exs. Dialyzer
        # cannot: plugins depend on the root, not the reverse, so each plugin's
        # precommit runs its own dialyzer.
        "cmd --cd plugins/provider_fake mix precommit",
        "cmd --cd plugins/provider_openai mix precommit",
        "cmd --cd plugins/tool_read mix precommit",
        "cmd --cd plugins/tool_bash mix precommit",
        "cmd --cd plugins/tool_edit mix precommit",
        "cmd --cd plugins/tool_write mix precommit",
        "cmd --cd plugins/model_context_default mix precommit",
        "cmd --cd plugins/compaction_none mix precommit"
      ]
    ]
  end
end
