defmodule CodingAgent do
  @moduledoc """
  The terminal coding agent: Core with the bundled plugins, one session, and
  the TUI. Started with `mix helyx`.
  """

  @plugins [
    Helyx.Provider.OpenAI.Go,
    Helyx.Provider.OpenAI.Zen,
    Helyx.Provider.Fake,
    Helyx.ModelContext.Default,
    Helyx.Compaction.None,
    Helyx.Tool.Read,
    Helyx.Tool.Bash,
    Helyx.Tool.Edit,
    Helyx.Tool.Write
  ]

  @doc "The plugins the agent runs with."
  @spec plugins() :: [module()]
  def plugins, do: @plugins

  @doc """
  Starts Core and a session on `:model` in `:cwd`, then runs the TUI until
  the user quits. Returns `{:error, reason}` when the model ref or the
  plugin list is rejected.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    model = Keyword.fetch!(opts, :model)

    with {:ok, _core} <- Helyx.Core.start_link(plugins: @plugins),
         {:ok, session} <-
           Helyx.Session.start(Helyx.Core, model: model, cwd: Keyword.fetch!(opts, :cwd)) do
      Helyx.TUI.run(session: session, model: model)
    end
  end
end
