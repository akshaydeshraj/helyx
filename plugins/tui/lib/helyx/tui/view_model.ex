defmodule Helyx.TUI.ViewModel do
  @moduledoc """
  The TUI's view of a session: a pure fold over `Helyx.Event`.

  The TUI holds no session state of its own. Every event goes through
  `apply/2` and the screen renders from the result, so the fold is testable
  with scripted event lists.

  `cells` is the transcript, oldest first. A cell is one of:

    * `%Helyx.Message{}` – a completed user or assistant message
    * `{:tool, call, result}` – a tool call; `result` is nil while it runs,
      then the tool result message
    * `{:notice, text}` – an aborted or failed turn

  `streaming` is the open assistant message as a reversed block list, newest
  first — the session's convention, shared through `Helyx.Message.add_block/2`
  — or nil when none is streaming.
  """

  alias Helyx.{Event, Message}

  defstruct model: nil,
            cells: [],
            streaming: nil,
            running?: false,
            queue: %{steers: 0, follow_ups: 0}

  @type cell ::
          Message.t()
          | {:tool, Message.ToolCall.t(), Message.t() | nil}
          | {:notice, String.t()}

  @type t :: %__MODULE__{
          model: String.t(),
          cells: [cell()],
          streaming: [Message.block()] | nil,
          running?: boolean(),
          queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
        }

  @doc "A view model for a fresh session on `model`."
  @spec new(String.t()) :: t()
  def new(model), do: %__MODULE__{model: model}

  @doc "Folds one event into the view model."
  @spec apply(t(), Event.t()) :: t()
  def apply(vm, %Event{type: :agent_start}), do: %{vm | running?: true}

  def apply(vm, %Event{type: :agent_end, data: data}) do
    vm = %{vm | running?: false, streaming: nil}

    case data do
      %{stop_reason: :aborted} -> add_cell(vm, {:notice, "aborted"})
      %{stop_reason: :error, error: error} -> add_cell(vm, {:notice, "error: #{inspect(error)}"})
      _ -> vm
    end
  end

  def apply(vm, %Event{type: :message_start, data: %{message: %Message{role: :assistant}}}) do
    %{vm | streaming: []}
  end

  # The fold is total: a clause head matches the delta's key and value
  # shape, and anything malformed falls through to the catch-all.
  def apply(vm, %Event{type: :message_update, data: %{text_delta: delta}})
      when is_binary(delta) do
    stream(vm, {:text_delta, delta})
  end

  def apply(vm, %Event{type: :message_update, data: %{thinking_delta: delta}})
      when is_binary(delta) do
    stream(vm, {:thinking_delta, delta})
  end

  def apply(vm, %Event{type: :message_update, data: %{tool_call: %Message.ToolCall{} = call}}) do
    stream(vm, {:tool_call, call})
  end

  def apply(vm, %Event{type: :message_end, data: %{message: %Message{role: :user} = message}}) do
    add_cell(vm, message)
  end

  def apply(vm, %Event{type: :message_end, data: %{message: %Message{role: :assistant} = message}}) do
    add_cell(%{vm | streaming: nil}, message)
  end

  def apply(vm, %Event{
        type: :tool_execution_start,
        data: %{tool_call: %Message.ToolCall{} = call}
      }) do
    add_cell(vm, {:tool, call, nil})
  end

  def apply(vm, %Event{type: :tool_execution_end, data: %{message: %Message{} = result}}) do
    %{vm | cells: attach_result(vm.cells, result)}
  end

  def apply(vm, %Event{type: :queue_update, data: %{steers: steers, follow_ups: follow_ups}})
      when is_integer(steers) and is_integer(follow_ups) do
    %{vm | queue: %{steers: steers, follow_ups: follow_ups}}
  end

  def apply(vm, %Event{}), do: vm

  defp stream(vm, delta), do: %{vm | streaming: Message.add_block(vm.streaming || [], delta)}

  defp add_cell(vm, cell), do: %{vm | cells: vm.cells ++ [cell]}

  # Tool calls run one at a time, so an open tool cell is always the last
  # cell. A result that matches nothing (an abort answering a call that
  # never started) changes nothing.
  defp attach_result(cells, result) do
    case List.last(cells) do
      {:tool, %Message.ToolCall{id: id} = call, nil} ->
        if id == result.tool_call_id do
          List.replace_at(cells, -1, {:tool, call, result})
        else
          cells
        end

      _ ->
        cells
    end
  end
end
