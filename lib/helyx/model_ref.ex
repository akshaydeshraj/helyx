defmodule Helyx.ModelRef do
  @moduledoc """
  The string that names a model for a session, in the form `provider/model`.

  The prefix selects the provider plugin. The rest is passed to the provider
  unchanged. Core parses it once; everything after that works with the struct.
  """

  @enforce_keys [:provider, :model]
  defstruct [:provider, :model]

  @type t :: %__MODULE__{provider: String.t(), model: String.t()}

  @doc "Splits `provider/model` at the first slash. Both parts must be present."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_model_ref, String.t()}}
  def parse(string) when is_binary(string) do
    case String.split(string, "/", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        {:ok, %__MODULE__{provider: provider, model: model}}

      _ ->
        {:error, {:invalid_model_ref, string}}
    end
  end

  @doc "Joins the struct back into the `provider/model` form."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{provider: provider, model: model}), do: provider <> "/" <> model
end
