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
    [{:helyx, path: "../.."}]
  end

  defp aliases do
    [precommit: ["format", "compile --warnings-as-errors", "test"]]
  end
end
