defmodule Helyx.Session.Transcript do
  @moduledoc false
  # Queries over a session transcript, a list of `Helyx.Message` in order.

  alias Helyx.{Message, ModelRef}

  # The tool calls in the transcript that have no tool result yet, in call
  # order. During a turn this is exactly the calls still to answer; on a
  # transcript restored after a crash it is the calls the crash orphaned.
  # A result answers the first still-open earlier call with its id, so a
  # call id a provider reuses in a later turn stays open until its own
  # result arrives.
  @spec open_calls([Message.t()]) :: [Message.ToolCall.t()]
  def open_calls(transcript) do
    Enum.reduce(transcript, [], fn
      %Message{role: :assistant, content: content}, open ->
        open ++ for %Message.ToolCall{} = call <- content, do: call

      %Message{role: :tool_result, tool_call_id: id}, open ->
        # Deleting nil is a no-op, so a result with no open call changes
        # nothing.
        List.delete(open, Enum.find(open, &(&1.id == id)))

      _message, open ->
        open
    end)
  end

  # The last assistant message, with no reversed copy of the transcript.
  @spec last_assistant([Message.t()]) :: Message.t() | nil
  def last_assistant(transcript) do
    Enum.reduce(transcript, nil, fn
      %Message{role: :assistant} = message, _last -> message
      _message, last -> last
    end)
  end

  # The harness session to resume, or nil: the last harness session of
  # `provider` in `harness_sessions` (its id and the number of transcript
  # messages before it started), when the last assistant message of the
  # transcript came from this provider after that session started. A
  # message of the harness session shows that it read the replay and the
  # prompt. Otherwise the harness does not have the transcript's end
  # (another provider answered last, or a fresh session ended before its
  # first message), and a fresh session gets it from the provider.
  @spec resumable([Message.t()], %{String.t() => {String.t(), non_neg_integer()}}, String.t()) ::
          String.t() | nil
  def resumable(transcript, harness_sessions, provider) do
    with {:ok, {harness_id, before}} <- Map.fetch(harness_sessions, provider),
         # Enum.drop/2 shares the tail of the list; it does not copy it.
         %Message{model: model} when is_binary(model) <-
           last_assistant(Enum.drop(transcript, before)),
         {:ok, %ModelRef{provider: ^provider}} <- ModelRef.parse(model) do
      harness_id
    else
      _other -> nil
    end
  end
end
