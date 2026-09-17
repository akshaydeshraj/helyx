defmodule Helyx.Hands do
  @moduledoc """
  Runs tool calls for one session in one working directory. See ADR 0003.

  The session starts the hands and addresses it by pid. Each tool call runs
  in a Task under Core's task supervisor. The result goes back to the session
  as `{:tool_result, turn_id, call_id, {:ok, text} | {:error, text}}`. A Task
  that dies without a result gives an error result, and so does a working
  directory that is gone when the call starts. Tool calls and results are
  plain terms.
  """

  use GenServer

  alias Helyx.Message.ToolCall

  defmodule State do
    @moduledoc false
    # `tools` is the tool module by name. `tasks` is the call each running
    # Task belongs to, by monitor ref.
    @enforce_keys [:core, :cwd, :session]
    defstruct [:core, :cwd, :session, tools: %{}, tasks: %{}]
  end

  @doc "Starts the hands for a session. Takes `core:`, `cwd:`, and `session:`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, struct!(State, opts))

  @doc "Returns the specs of the tools the hands can run."
  @spec tools(pid()) :: [Helyx.Tool.spec()]
  def tools(hands), do: GenServer.call(hands, :tools)

  @doc "Starts a tool call. The result is sent to the session."
  @spec run(pid(), String.t(), ToolCall.t()) :: :ok
  def run(hands, turn_id, %ToolCall{} = call), do: GenServer.call(hands, {:run, turn_id, call})

  # The tool table comes from Core. The session checks it for duplicate
  # names before it starts the hands, so this match holds.
  @impl true
  def init(%State{core: core} = state) do
    {:ok, tools} = Helyx.Tool.by_name(core)
    {:ok, %{state | tools: tools}}
  end

  @impl true
  def handle_call(:tools, _from, state) do
    {:reply, Enum.map(Map.values(state.tools), &Helyx.Tool.spec/1), state}
  end

  def handle_call({:run, turn_id, call}, _from, state) do
    tool = if File.dir?(state.cwd), do: Map.get(state.tools, call.name, :unknown), else: :no_cwd

    task =
      Task.Supervisor.async_nolink(Helyx.Core.task_supervisor(state.core), fn ->
        run_tool(tool, call, state.cwd)
      end)

    {:reply, :ok, %{state | tasks: Map.put(state.tasks, task.ref, {turn_id, call.id})}}
  end

  @impl true
  def handle_info({ref, result}, %State{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, deliver(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, deliver(ref, {:error, "tool crashed: #{inspect(reason)}"}, state)}
  end

  # A reply or :DOWN for a Task that was already delivered.
  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(ref, result, state) do
    {{turn_id, call_id}, tasks} = Map.pop!(state.tasks, ref)
    send(state.session, {:tool_result, turn_id, call_id, result})
    %{state | tasks: tasks}
  end

  defp run_tool(:unknown, call, _cwd), do: {:error, "unknown tool: #{call.name}"}
  defp run_tool(:no_cwd, _call, cwd), do: {:error, "working directory does not exist: #{cwd}"}

  defp run_tool(tool, call, cwd) do
    case tool.run(call.arguments, cwd) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, text} when is_binary(text) -> {:error, text}
      other -> {:error, "tool #{call.name} returned #{inspect(other)}"}
    end
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end
end
