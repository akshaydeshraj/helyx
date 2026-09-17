defmodule Helyx.Interface do
  @moduledoc """
  Marks a module as a Helyx interface.

  An interface is a behaviour plus a public API. It declares how many plugins
  can be active at once:

      use Helyx.Interface, mode: :single
      use Helyx.Interface, mode: :multi, required: true

  `:single` means exactly one plugin when present. `:multi` means any number.
  `required: true` means Core refuses to boot without at least one plugin.
  """

  @type mode :: :single | :multi

  defmacro __using__(opts) do
    mode = Keyword.fetch!(opts, :mode)
    required = Keyword.get(opts, :required, false)

    unless mode in [:single, :multi] do
      raise ArgumentError, "mode must be :single or :multi, got: #{inspect(mode)}"
    end

    quote do
      @doc false
      def __helyx_interface__, do: %{mode: unquote(mode), required: unquote(required)}
    end
  end

  @doc "Returns the interface declaration of a module, or `nil` if it is not an interface."
  @spec declaration(module()) :: %{mode: mode(), required: boolean()} | nil
  def declaration(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :__helyx_interface__, 0) do
      module.__helyx_interface__()
    end
  end

  @doc "Returns the interfaces a plugin module implements, in declaration order."
  @spec implemented_by(module()) :: [module()]
  def implemented_by(plugin) do
    Code.ensure_loaded(plugin)

    plugin.__info__(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.filter(&declaration/1)
  end
end
