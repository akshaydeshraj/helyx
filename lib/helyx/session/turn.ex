defmodule Helyx.Session.Turn do
  @moduledoc false
  # The turn in progress. `partial` is the assistant content so far as a
  # reversed block list, or nil before the first stream event. `calls` are
  # the tool calls still to answer, the head running. `rejected` are the
  # tool calls of the current assistant message that get an error result
  # and never run, because their arguments held an integer over the digit
  # limit (see `Helyx.Message.cap_integers/1`). They are compared by value,
  # because a provider can repeat a call id: a call that is equal to a
  # rejected call after the cap is also rejected. One turn has many provider
  # calls, so each provider call starts with an empty list.
  # `model` and `provider` are fixed when the turn starts, so a model switch
  # during the turn takes effect on the next one, and so does `kind`
  # (`Helyx.Provider.kind/1`). `resumed` is the harness session id the
  # turn passed to a harness provider, or nil.

  alias Helyx.{Message, ModelRef}

  @enforce_keys [:id, :model, :provider, :kind]
  defstruct [:id, :model, :provider, :kind, :task, :partial, :resumed, calls: [], rejected: []]

  @type t :: %__MODULE__{}

  # Adds one stream event to the partial assistant content.
  @spec add_block(t(), Message.block_event()) :: t()
  def add_block(%__MODULE__{partial: partial} = turn, event),
    do: %{turn | partial: Message.add_block(partial, event)}

  # The assistant message of the turn from the blocks so far, with `fields`.
  @spec assistant_message(t(), keyword()) :: Message.t()
  def assistant_message(%__MODULE__{partial: partial, model: model}, fields) do
    struct!(
      %Message{
        role: :assistant,
        content: Enum.reverse(partial),
        model: ModelRef.to_string(model)
      },
      fields
    )
  end

  @spec reject(t(), Message.ToolCall.t()) :: t()
  def reject(%__MODULE__{rejected: rejected} = turn, call),
    do: %{turn | rejected: [call | rejected]}

  @spec rejected?(t(), Message.ToolCall.t()) :: boolean()
  def rejected?(%__MODULE__{rejected: rejected}, call), do: call in rejected
end
