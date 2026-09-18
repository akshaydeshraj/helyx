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
  Starts Core and a session, then runs the TUI until the user quits. The
  session is written under `:sessions_dir` (default `~/.helyx/sessions`);
  with `resume: true` the most recent session for `:cwd` is resumed and
  keeps its saved model. Returns `{:error, reason}` when the model ref, the
  plugin list, or the resume is rejected.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    with {:ok, _core} <- Helyx.Core.start_link(plugins: @plugins),
         {:ok, session} <- start_session(opts),
         {:ok, model} <- fetch_model(session) do
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

  # A session that dies right after starting must reach the task's
  # `{:error, reason}` surface, not exit the VM with a raw dump.
  defp fetch_model(session) do
    {:ok, Helyx.Session.model(session)}
  catch
    :exit, reason -> {:error, {:session_down, reason}}
  end

  @doc """
  Starts or resumes the session `run/1` uses. Public so tests can drive the
  wiring without the terminal. `:core` defaults to `Helyx.Core`.
  """
  @spec start_session(keyword()) :: {:ok, Helyx.Session.t()} | {:error, term()}
  def start_session(opts) do
    core = Keyword.get(opts, :core, Helyx.Core)
    cwd = Keyword.fetch!(opts, :cwd)
    dir = Keyword.get_lazy(opts, :sessions_dir, fn -> Path.expand("~/.helyx/sessions") end)

    if opts[:resume] do
      Helyx.Session.resume(core, sessions_dir: dir, cwd: cwd)
    else
      Helyx.Session.start(core,
        model: Keyword.fetch!(opts, :model),
        cwd: cwd,
        sessions_dir: dir
      )
    end
  end
end
