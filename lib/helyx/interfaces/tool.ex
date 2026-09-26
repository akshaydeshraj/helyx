defmodule Helyx.Tool do
  @moduledoc """
  A tool the model can call. The hands run it in the session's working
  directory.

  A tool plugin implements this behaviour. `name/0` is what the model calls.
  `parameters/0` is a JSON schema map with string keys. `run/2` gets the
  decoded argument map and the working directory, and returns the text the
  model sees. `{:error, text}` marks the result as an error; a tool that
  raises is reported the same way.

  The optional `check/0` runs when the hands start. A tool that needs
  something from the system, an executable for example, reports it missing
  there. Then the session fails to start with a clear error, and no call
  fails later for that reason.

  A tool that creates an OS resource, a process group for example, holds it
  with `hold/1` before the external work starts, and implements the
  optional `release/3`. The hands call `release(handles, mode, deadline)`
  with the handles of a call when it delivers (`:deliver`), when its turn is
  aborted (`:cancel`), and before a later call for handles that an earlier
  release did not confirm (`:retry`). `deadline` is absolute, in
  `System.monotonic_time(:millisecond)` on the node of the hands. The return
  value is the handles still held; `[]` means every one is released. The
  callback must be safe to call again with the same handles, and it must
  not wait past the deadline. The tool must also free the resource by
  itself when its Task dies with no release, because the hands can die
  first and drop a late `hold/1` (ADR 0004); the bash tool's watchdog does
  this when its port closes.
  """

  use Helyx.Interface, mode: :multi

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(arguments :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback check() :: :ok | {:error, String.t()}
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel | :retry,
              deadline :: integer()
            ) ::
              [term()]

  @optional_callbacks check: 0, release: 3

  @doc """
  Builds the spec of each registered tool plugin, checks it, and returns
  the tools sorted by name. The session calls this once at start, so the
  callbacks `name/0`, `description/0`, and `parameters/0` run once per
  session, and every provider call uses the checked value.

  A spec is accepted when `name` is a non-empty string of valid UTF-8,
  `description` is a string of valid UTF-8, and `parameters` is a map with
  string keys at the top level that `Helyx.Message.encodable?/1` accepts.
  Otherwise the result is `{:error, {:bad_tool_spec, label}}`: the label is
  the name when the name is accepted, else the module name. Two tools with
  one name give `{:error, {:duplicate_tool_name, name}}`.
  """
  @spec specs(Helyx.Core.name()) ::
          {:ok, [{module(), spec()}]}
          | {:error, {:bad_tool_spec, String.t()} | {:duplicate_tool_name, String.t()}}
  def specs(core) do
    tools =
      core
      |> Helyx.Core.plugins(__MODULE__)
      |> Enum.map(
        &{&1, %{name: &1.name(), description: &1.description(), parameters: &1.parameters()}}
      )
      |> Enum.sort_by(fn {_tool, spec} -> spec.name end)

    with :ok <- check_specs(tools), :ok <- check_unique(tools), do: {:ok, tools}
  end

  defp check_specs(tools) do
    Enum.find_value(tools, :ok, fn {tool, spec} ->
      cond do
        not text?(spec.name) or spec.name == "" ->
          {:error, {:bad_tool_spec, inspect(tool)}}

        not text?(spec.description) or not parameters?(spec.parameters) ->
          {:error, {:bad_tool_spec, spec.name}}

        true ->
          nil
      end
    end)
  end

  defp check_unique(tools) do
    names = Enum.map(tools, fn {_tool, spec} -> spec.name end)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_tool_name, dup}}
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp parameters?(value) when is_map(value),
    do: Enum.all?(Map.keys(value), &is_binary/1) and Helyx.Message.encodable?(value)

  defp parameters?(_value), do: false

  @doc """
  Holds an opaque handle of a resource the tool call created with the hands
  that run it. The hands keep it outside the Task and give it to the tool's
  `release/3` when the call delivers or its turn is aborted, so no resource
  outlives the call. Returns only when the hands hold the handle, so work
  that starts after it is never unheld. A no-op when the tool runs outside
  the hands. Raises when the tool does not implement `release/3`.
  """
  @spec hold(term()) :: :ok
  def hold(handle) do
    case Process.get(:helyx_hands) do
      nil ->
        :ok

      hands ->
        case GenServer.call(hands, {:hold, handle}, :infinity) do
          :ok -> :ok
          :no_release -> raise ArgumentError, "a tool without release/3 cannot hold a resource"
        end
    end
  end
end
