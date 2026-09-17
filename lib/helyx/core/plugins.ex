defmodule Helyx.Core.Plugins do
  @moduledoc false
  # Holds the resolved plugin table for one Core instance.

  use Agent

  @type table :: %{module() => [module()]}

  def start_link(opts) do
    table = Keyword.fetch!(opts, :table)
    Agent.start_link(fn -> table end, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Groups plugins by interface and checks each interface's mode.

  `interfaces` lists the interfaces Core knows about. Each one is checked even
  when no plugin implements it, so a required interface with no plugin is an
  error. An interface that only appears through a plugin's `@behaviour` is
  checked too.
  """
  @spec resolve([module()], [module()]) :: {:ok, table()} | {:error, term()}
  def resolve(plugins, interfaces) do
    with {:ok, table} <- group(plugins) do
      check_modes(table, Enum.uniq(interfaces ++ Map.keys(table)))
    end
  end

  def for_interface(name, interface) do
    Agent.get(name, &Map.get(&1, interface, []))
  end

  defp group(plugins) do
    Enum.reduce_while(plugins, {:ok, %{}}, fn plugin, {:ok, acc} ->
      case Helyx.Interface.implemented_by(plugin) do
        [] ->
          {:halt, {:error, {:not_a_plugin, plugin}}}

        interfaces ->
          acc =
            Enum.reduce(interfaces, acc, fn interface, acc ->
              Map.update(acc, interface, [plugin], &(&1 ++ [plugin]))
            end)

          {:cont, {:ok, acc}}
      end
    end)
  end

  defp check_modes(table, interfaces) do
    Enum.reduce_while(interfaces, {:ok, table}, fn interface, {:ok, table} ->
      case Helyx.Interface.declaration(interface) do
        nil ->
          {:halt, {:error, {:not_an_interface, interface}}}

        %{mode: mode, required: required} ->
          plugins = Map.get(table, interface, [])

          cond do
            required and plugins == [] ->
              {:halt, {:error, {:missing_plugin, interface}}}

            mode == :single and length(plugins) > 1 ->
              {:halt, {:error, {:mode_violation, interface, plugins}}}

            true ->
              {:cont, {:ok, table}}
          end
      end
    end)
  end
end
