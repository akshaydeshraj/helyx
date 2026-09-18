defmodule Helyx.TUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :helyx_tui,
      version: "0.1.0",
      elixir: "~> 1.19",
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

  defp deps do
    [
      {:helyx, path: "../.."},
      {:ex_ratatui, "~> 0.14"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:helyx_provider_fake, path: "../provider_fake", only: :test}
    ]
  end

  defp aliases do
    [precommit: ["format", "compile --warnings-as-errors", "dialyzer --force-check", "test"]]
  end
end
