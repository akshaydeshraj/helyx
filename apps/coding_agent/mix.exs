defmodule CodingAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # The Mix task calls Mix.Task.run/1 and Mix.raise/1; :mix is not in
      # the default PLT.
      dialyzer: [plt_add_apps: [:mix]]
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
      {:helyx_tui, path: "../../plugins/tui"},
      {:helyx_provider_openai, path: "../../plugins/provider_openai"},
      {:helyx_provider_fake, path: "../../plugins/provider_fake"},
      {:helyx_model_context_default, path: "../../plugins/model_context_default"},
      {:helyx_compaction_none, path: "../../plugins/compaction_none"},
      {:helyx_tool_read, path: "../../plugins/tool_read"},
      {:helyx_tool_bash, path: "../../plugins/tool_bash"},
      {:helyx_tool_edit, path: "../../plugins/tool_edit"},
      {:helyx_tool_write, path: "../../plugins/tool_write"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [precommit: ["format", "compile --warnings-as-errors", "dialyzer --force-check", "test"]]
  end
end
