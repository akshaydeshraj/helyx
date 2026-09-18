defmodule Helyx.Provider.Fake.MixProject do
  use Mix.Project

  def project do
    [
      app: :helyx_provider_fake,
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "deps.get --check-locked",
        "format",
        "compile --warnings-as-errors",
        "dialyzer --force-check",
        "test"
      ]
    ]
  end
end
