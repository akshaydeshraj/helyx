defmodule Helyx.TUI.ViewModel do
  @moduledoc """
  The TUI's view of a session: a pure fold over `Helyx.Event`.

  The TUI holds no session state of its own. Every event goes through
  `apply/2` and the screen renders from the result, so the fold is testable
  with scripted event lists.

  `cells` is the transcript, oldest first. A cell is one of:

    * `%Helyx.Message{}` – a completed user or assistant message
    * `{:tool, call, line, result}` – a tool call and its line
      (`call_line/1`), made once when the call starts, so a frame does not
      pay for the size of the call; `result` is nil while it runs, then the
      tool result message
    * `{:notice, text}` – an aborted or failed turn, a harness that lost
      its session or got a cut transcript, or a command the client rejected
      (`notice/2`)

  `reason` is why the client rejected the last input, or nil. It is
  client-local, like a notice: `reject/2` sets it and `clear_reason/1`
  clears it on the next key press or paste. A new reject replaces it. No event changes it.

  `streaming` is the open assistant message as a reversed block list, newest
  first — the session's convention, shared through `Helyx.Message.add_block/2`
  — or nil when none is streaming.
  """

  alias Helyx.{Event, Message}

  # The cut of an error notice or a tool call line (`cut_line/1`).
  @render_max_bytes 8_192

  defstruct model: nil,
            cells: [],
            streaming: nil,
            running?: false,
            queue: %{steers: 0, follow_ups: 0},
            reason: nil

  @type cell ::
          Message.t()
          | {:tool, Message.ToolCall.t(), String.t(), Message.t() | nil}
          | {:notice, String.t()}

  @type t :: %__MODULE__{
          model: String.t(),
          cells: [cell()],
          streaming: [Message.block()] | nil,
          running?: boolean(),
          queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()},
          reason: String.t() | nil
        }

  @doc "A view model for a fresh session on `model`."
  @spec new(String.t()) :: t()
  def new(model), do: %__MODULE__{model: model}

  @doc """
  Folds one event into the view model. Core makes every event from checked
  data, so the fold trusts the shapes of `Helyx.Event`. An event of another
  shape is a bug in Core and crashes the TUI.
  """
  @spec apply(t(), Event.t()) :: t()
  def apply(vm, %Event{type: :agent_start}), do: %{vm | running?: true}

  def apply(vm, %Event{type: :agent_end, data: data}) do
    vm = %{vm | running?: false, streaming: nil}

    case data do
      %{stop_reason: :aborted} ->
        add_cell(vm, {:notice, "aborted"})

      %{stop_reason: :error, error: error} ->
        add_cell(vm, {:notice, "error: " <> error_text(error)})

      %{stop_reason: _other} ->
        vm
    end
  end

  # The TUI shows a turn only through its messages, and a user message
  # when it ends.
  def apply(vm, %Event{type: type}) when type in [:turn_start, :turn_end], do: vm
  def apply(vm, %Event{type: :message_start, data: %{message: %Message{role: :user}}}), do: vm

  def apply(vm, %Event{type: :message_start, data: %{message: %Message{role: :assistant}}}) do
    %{vm | streaming: []}
  end

  def apply(vm, %Event{type: :message_update, data: %{text_delta: delta}}) do
    stream(vm, {:text_delta, delta})
  end

  def apply(vm, %Event{type: :message_update, data: %{thinking_delta: delta}}) do
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
    add_cell(vm, {:tool, call, call_line(call), nil})
  end

  def apply(vm, %Event{
        type: :tool_execution_end,
        data: %{message: %Message{role: :tool_result} = result}
      }) do
    %{vm | cells: attach_result(vm.cells, result)}
  end

  def apply(vm, %Event{type: :queue_update, data: %{steers: steers, follow_ups: follow_ups}}) do
    %{vm | queue: %{steers: steers, follow_ups: follow_ups}}
  end

  def apply(vm, %Event{type: :model_change, data: %{model: model}}), do: %{vm | model: model}

  def apply(vm, %Event{
        type: :harness_session,
        data: %{provider: provider, lost: lost, cut: cut}
      }) do
    vm = if lost, do: add_cell(vm, {:notice, lost_text(provider)}), else: vm

    if cut > 0,
      do:
        add_cell(
          vm,
          {:notice, "#{provider} got the transcript without its #{cut} oldest messages"}
        ),
      else: vm
  end

  @doc "Adds a notice from the client itself, such as a rejected command."
  @spec notice(t(), String.t()) :: t()
  def notice(vm, text) when is_binary(text), do: add_cell(vm, {:notice, text})

  @doc "Sets the reason the status bar shows for a rejected input."
  @spec reject(t(), String.t()) :: t()
  def reject(vm, reason) when is_binary(reason), do: %{vm | reason: reason}

  @doc "Clears the reason. The TUI calls it on a key press or a paste when a reason is set."
  @spec clear_reason(t()) :: t()
  def clear_reason(vm), do: %{vm | reason: nil}

  defp lost_text(provider),
    do: "#{provider} lost its own session; a fresh one got the transcript"

  @doc """
  The line of a tool call: its name, then each argument as `key=value`,
  with the key raw and the value through `inspect/1`, cut at
  #{@render_max_bytes} bytes. The name and each key are cut before they join
  the line, the walk over the arguments stops once the line is over the cut,
  and the line is cut before its newlines become "␤". The fold makes the line
  once, when the call starts, and not on each frame.
  """
  @spec call_line(Message.ToolCall.t()) :: String.t()
  def call_line(%Message.ToolCall{name: name, arguments: arguments}) do
    ("⚙ " <> cut_line(name))
    |> join_arguments(arguments |> :maps.iterator() |> :maps.next())
    |> cut_line()
    |> String.replace("\n", "␤")
    |> cut_line()
  end

  # `:maps.next/1` walks the map lazily, so a call of many keys costs no
  # more than the keys up to the cut.
  defp join_arguments(line, :none), do: line
  defp join_arguments(line, _next) when byte_size(line) > @render_max_bytes, do: line

  defp join_arguments(line, {key, value, iterator}),
    do: join_arguments("#{line} #{cut_line("#{key}")}=#{inspect(value)}", :maps.next(iterator))

  # One rule for an error notice or a tool call line that holds provider or
  # model text: `inspect/1` escapes a character to up to four times its
  # bytes (a control or invalid byte renders as `\x01`) and has no total
  # limit over nested terms, so the text is cut at `@render_max_bytes`; a
  # character cut in half is dropped.
  defp cut_line(text),
    do: text |> binary_slice(0, @render_max_bytes) |> String.replace_invalid("")

  # `binaries: :as_strings` escapes a control or invalid byte, so an error
  # text shows as text, not as a list of bytes.
  defp error_text(error), do: error |> inspect(binaries: :as_strings) |> cut_line()

  defp stream(vm, delta), do: %{vm | streaming: Message.add_block(vm.streaming || [], delta)}

  defp add_cell(vm, cell), do: %{vm | cells: vm.cells ++ [cell]}

  # The result goes to the newest open tool cell with the same call id,
  # wherever it is: a notice can arrive while the tool runs (#83). A cell
  # that has a result never changes. A result that matches no open cell (an
  # abort answering a call that never started) changes nothing. The search
  # is one pass over the cells for each result.
  defp attach_result(cells, %Message{tool_call_id: id} = result) do
    open? = &match?({:tool, %Message.ToolCall{id: ^id}, _line, nil}, &1)

    case Enum.find_index(Enum.reverse(cells), open?) do
      nil ->
        cells

      index ->
        List.update_at(cells, -1 - index, fn {:tool, call, line, nil} ->
          {:tool, call, line, result}
        end)
    end
  end
end
