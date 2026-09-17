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

  Every interface in `interfaces` is checked even when no plugin implements
  it, so a required interface with no plugin is an error. An interface that
  only appears through a plugin's `@behaviour` is checked too.
  """
  @spec resolve([module()], [module()]) :: {:ok, table()} | {:error, term()}
  def resolve(plugins, interfaces) do
    with {:ok, table} <- group(plugins) do
      interfaces = Enum.uniq(interfaces ++ Map.keys(table))

      case Enum.find_value(interfaces, &check_mode(&1, Map.get(table, &1, []))) do
        nil -> {:ok, table}
        error -> {:error, error}
      end
    end
  end

  def for_interface(name, interface) do
    Agent.get(name, &Map.get(&1, interface, []))
  end

  defp group(plugins) do
    implemented = Enum.map(plugins, &{&1, Helyx.Interface.implemented_by(&1)})

    case Enum.find(implemented, &match?({_, []}, &1)) do
      {plugin, []} ->
        {:error, {:not_a_plugin, plugin}}

      nil ->
        pairs =
          for {plugin, interfaces} <- implemented,
              interface <- interfaces,
              do: {interface, plugin}

        {:ok, Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))}
    end
  end

  # Returns the error for an interface and its plugins, or nil when they fit.
  defp check_mode(interface, plugins) do
    case {Helyx.Interface.declaration(interface), plugins} do
      {%{required: true}, []} -> {:missing_plugin, interface}
      {%{mode: :single}, [_, _ | _]} -> {:mode_violation, interface, plugins}
      _ -> nil
    end
  end
end
