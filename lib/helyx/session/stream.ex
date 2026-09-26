defmodule Helyx.Session.Stream do
  @moduledoc false
  # The work of one provider call. `run/1` runs in the provider Task: it
  # builds the context, compacts it, calls the provider, checks each stream
  # event, and sends each event that passes to the session. It returns the
  # first terminal. It holds no resource and makes no decision of the turn.

  alias Helyx.Message

  @stop_reasons Message.stop_reasons()

  # The harness providers cut each tool result (`Helyx.Provider`). Every
  # output of that cut is at most 51,201 bytes of lines and a notice of less
  # than 200 bytes, so only a result that was not cut is over this limit.
  @max_tool_result_bytes 65_536

  @type terminal ::
          {:done, %{stop_reason: atom(), usage: map()}} | {:error, term()} | :stream_ended

  @type args :: %{
          model_context: module() | nil,
          compaction: module() | nil,
          provider: module(),
          model: String.t(),
          context: Helyx.Context.t(),
          opts: keyword(),
          session: pid(),
          turn_id: String.t(),
          external?: boolean()
        }

  @doc """
  Runs one provider call. Sends the session `{:stream_event, turn_id, event}`
  for each event that passes the checks, and `{:rejected_call, turn_id, call}`
  before the stream event of a call with an integer over the digit limit.
  """
  @spec run(args()) :: terminal()
  def run(%{
        model_context: model_context,
        compaction: compaction,
        provider: provider,
        model: model,
        context: context,
        opts: opts,
        session: session,
        turn_id: turn_id,
        external?: external?
      }) do
    # Context building runs inside the Task so plugin code never blocks the
    # session and a plugin that raises fails the turn, not the session.
    # The session resolved both plugins at its start; nil means none, and
    # the context goes on unchanged.
    context = if model_context, do: model_context.build(context, opts), else: context
    context = if compaction, do: compaction.compact(context, opts), else: context

    result =
      case provider.stream(model, context, opts) do
        {:ok, stream} -> consume(stream, session, turn_id, external?)
        {:error, reason} -> {:error, reason}
      end

    # Every terminal leaves the Task through this cap, so no error reason
    # and no malformed event in one brings an integer over the digit
    # limit to the session (see `Helyx.Message.cap_integers/1`). A raise
    # or an exit is not a terminal: the `:DOWN` handler of the session, or
    # the hands for the stream of an external turn, report it.
    Message.cap_integers(result)
  end

  # Forwards well-formed stream events to the session and returns the first
  # terminal event. A malformed event is a terminal error. Arguments or a
  # usage that are a struct are malformed: `cap_integers/1` can turn a struct
  # into a string, and the session file needs a plain map. A delta or a
  # tool call that is not valid UTF-8 is malformed: transcript text is
  # valid from the moment it exists, so the file and the providers never
  # see raw bytes.
  defp consume(stream, session, turn_id, external?) do
    Enum.reduce_while(stream, :stream_ended, fn
      {kind, payload} = event, acc
      when kind in [:text_delta, :thinking_delta] and is_binary(payload) ->
        forward(Message.valid_utf8?(payload), event, session, turn_id, acc)

      {:tool_call, %Message.ToolCall{id: id, name: name, arguments: args}}, acc
      when is_binary(id) and is_binary(name) and is_non_struct_map(args) ->
        # The one place where tool call arguments enter the session from a
        # provider (on resume, Session.File applies the same function). An
        # integer over the digit limit is replaced here, before the first
        # JSON encode, which is quadratic in the digits (#79). The
        # transcript, the events, the session file, the tool, and the next
        # provider request thus never hold it.
        capped = Message.cap_integers(args)
        # A new struct: the pattern also matches a call with one more key.
        call = %Message.ToolCall{id: id, name: name, arguments: capped}
        if capped != args, do: send(session, {:rejected_call, turn_id, call})
        forward(Message.encodable?([id, name, capped]), {:tool_call, call}, session, turn_id, acc)

      # The stop reason set is closed (`Message.stop_reasons/0`), and the
      # session file holds only JSON. A terminal whose stop reason is outside
      # the set, or whose usage the file cannot encode, fails the turn here,
      # before the message exists, instead of raising in persist and silently
      # turning persistence off for the rest of the session.
      {:done, %{stop_reason: reason, usage: usage}} = terminal, _acc
      when reason in @stop_reasons and is_non_struct_map(usage) ->
        # A new plain map: the pattern also matches a struct and a map with
        # more keys, and the session needs this shape after the cap at the
        # Task exit.
        {:halt, done_terminal(reason, capped_usage(usage), terminal)}

      {:error, _} = terminal, _acc ->
        {:halt, terminal}

      # Only a provider with an external turn sends these; in a local turn
      # they are malformed.
      {tag, _, _} = event, acc
      when external? and tag in [:message_end, :tool_result, :harness_session] ->
        case external_event(event) do
          {:ok, event} -> forward(true, event, session, turn_id, acc)
          {:error, _} = terminal -> {:halt, terminal}
        end

      other, _acc ->
        {:halt, {:error, {:bad_stream_event, other}}}
    end)
  end

  # The events of an external turn. A message end is checked like the
  # `done` terminal. The provider cuts a result to the tool result limits;
  # a result over this limit was not cut, so it fails the turn. The check
  # measures the text as sent, before the UTF-8 repair of
  # `Helyx.Message.tool_result/2`, which can make it up to three times larger.
  defp external_event({:message_end, reason, usage} = event)
       when reason in @stop_reasons and is_non_struct_map(usage) do
    case capped_usage(usage) do
      {:ok, usage} -> {:ok, {:message_end, reason, usage}}
      :error -> malformed(event)
    end
  end

  defp external_event({:tool_result, id, {status, text}} = event)
       when is_binary(id) and status in [:ok, :error] and is_binary(text) do
    cond do
      not Message.valid_utf8?(id) -> malformed(event)
      byte_size(text) > @max_tool_result_bytes -> {:error, too_large(text)}
      true -> {:ok, event}
    end
  end

  defp external_event({:harness_session, id, cut} = event) when is_integer(cut) and cut >= 0 do
    # No integer over the digit limit reaches the session (see
    # `Helyx.Message.cap_integers/1`).
    if Message.harness_id?(id) and Message.cap_integers(cut) == cut,
      do: {:ok, event},
      else: malformed(event)
  end

  defp external_event(event), do: malformed(event)

  defp malformed(event), do: {:error, {:bad_stream_event, event}}

  # The error holds the size, never the text.
  defp too_large(text), do: {:tool_result_too_large, byte_size(text), @max_tool_result_bytes}

  defp done_terminal(reason, {:ok, usage}, _terminal),
    do: {:done, %{stop_reason: reason, usage: usage}}

  defp done_terminal(_reason, :error, terminal), do: {:error, {:bad_stream_event, terminal}}

  # The usage gets the same encodes as the arguments, so the same cap.
  defp capped_usage(usage) do
    usage = Message.cap_integers(usage)
    if Message.encodable?(usage), do: {:ok, usage}, else: :error
  end

  defp forward(true = _valid, event, session, turn_id, acc) do
    send(session, {:stream_event, turn_id, event})
    {:cont, acc}
  end

  defp forward(false = _valid, event, _session, _turn_id, _acc),
    do: {:halt, {:error, {:bad_stream_event, event}}}
end
