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
      result = Helyx.TUI.run(session: session, model: model)

      # Quitting mid-turn must not leave shell process groups running after
      # the VM stops; only abort makes the hands kill them and wait. A
      # session that died has no turn for abort to reach (ticket #45).
      try do
        Helyx.Session.abort(session)
      catch
        :exit, _ -> :ok
      end

      result
    end
  end
end
