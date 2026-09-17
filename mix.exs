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
    []
  end

  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "test",
        "cmd --cd plugins/provider_fake mix precommit",
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
