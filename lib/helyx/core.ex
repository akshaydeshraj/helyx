defmodule Helyx.Core do
  @moduledoc """
  Registers, resolves, and supervises plugins.

  Start Core as a child of the product's supervision tree with the plugin list:

      children = [{Helyx.Core, plugins: [Helyx.Provider.Fake]}]

  Core checks every plugin against the interfaces it implements. It refuses to
  start when a `:single` interface receives more than one plugin, when a
  `required: true` interface receives none, or when a module implements no
  interface at all.

  Core checks the interfaces in `interfaces()` by default. A product that
  defines its own interfaces passes the full list with `interfaces:`.

  A plugin that exports `child_spec/1` gets its process tree started under
  Core, with `[core: name]` as the argument.

  Several Core instances can run in one node under different names. Sessions
  and their subscribers are scoped to the Core that started them.
  """

  use Supervisor

  @type name :: atom()

  @interfaces [Helyx.Provider]

  @doc "The interfaces Core checks at boot when `interfaces:` is not given."
  @spec interfaces() :: [module()]
  def interfaces, do: @interfaces

  @doc "Child spec for a product's supervision tree. Takes `name:`, `plugins:`, and `interfaces:`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts Core. Returns the resolution error instead of a pid when the plugin list is invalid."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    plugins = Keyword.get(opts, :plugins, [])
    interfaces = Keyword.get(opts, :interfaces, @interfaces)

    with {:ok, table} <- Helyx.Core.Plugins.resolve(plugins, interfaces) do
      Supervisor.start_link(__MODULE__, {name, plugins, table}, name: name)
    end
  end

  @impl true
  def init({name, plugins, table}) do
    plugin_children =
      for plugin <- plugins, function_exported?(plugin, :child_spec, 1) do
        plugin.child_spec(core: name)
      end

    children =
      [
        {Helyx.Core.Plugins, name: plugins_name(name), table: table},
        {Registry, keys: :unique, name: sessions_registry(name)},
        {Registry, keys: :duplicate, name: events_registry(name)},
        {Task.Supervisor, name: task_supervisor(name)},
        {DynamicSupervisor, name: session_supervisor(name), strategy: :one_for_one}
      ] ++ plugin_children

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Returns the plugins registered for an interface, in registration order."
  @spec plugins(name(), module()) :: [module()]
  def plugins(name \\ __MODULE__, interface) do
    Helyx.Core.Plugins.for_interface(plugins_name(name), interface)
  end

  @doc "Finds the provider plugin whose id matches a model ref prefix."
  @spec provider(name(), String.t()) ::
          {:ok, module()} | {:error, {:unknown_provider, String.t()}}
  def provider(name \\ __MODULE__, id) do
    case Enum.find(plugins(name, Helyx.Provider), &(&1.id() == id)) do
      nil -> {:error, {:unknown_provider, id}}
      plugin -> {:ok, plugin}
    end
  end

  @doc false
  def sessions_registry(name), do: Module.concat(name, Sessions)
  @doc false
  def events_registry(name), do: Module.concat(name, Events)
  @doc false
  def task_supervisor(name), do: Module.concat(name, Tasks)
  @doc false
  def session_supervisor(name), do: Module.concat(name, SessionSupervisor)

  defp plugins_name(name), do: Module.concat(name, Plugins)
end
