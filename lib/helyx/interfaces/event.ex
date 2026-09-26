defmodule Helyx.Event do
  @moduledoc """
  A fact emitted by a session. Clients render from events and hold no other
  session state.

  Every event carries the session id, the turn id, and a sequence number that
  increases by one per event within a session, so a client can detect gaps.

  Types and their `data`:

    * `:agent_start` – `%{}`
    * `:turn_start` – `%{}`
    * `:message_start` – `%{message: Helyx.Message.t()}` (may be partial)
    * `:message_update` – `%{text_delta: binary}`, `%{thinking_delta: binary}`,
      or `%{tool_call: Helyx.Message.ToolCall.t()}`
    * `:message_end` – `%{message: Helyx.Message.t()}`; on a failed or
      aborted turn the partial assistant message has `:error` or `:aborted`
      as its stop reason and `data.error` holds the reason
    * `:tool_execution_start` – `%{tool_call: Helyx.Message.ToolCall.t()}`
    * `:tool_execution_end` – `%{message: Helyx.Message.t()}`, the tool
      result message; calls run one at a time, in call order
    * `:turn_end` – `%{message: Helyx.Message.t()}`
    * `:agent_end` – `%{stop_reason: atom}`, plus `error: term` on failure;
      an aborted turn ends with `stop_reason: :aborted` after a
      `:tool_execution_end` with an `aborted` error result for each open
      tool call
    * `:queue_update` – `%{steers: non_neg_integer, follow_ups: non_neg_integer}`,
      emitted whenever the session's message queues change; the drain at a
      normal turn end goes out between turns, with a nil turn id
    * `:model_change` – `%{model: String.t()}`, the new `provider/model` ref;
      the switch belongs to no turn, so the turn id is always nil
    * `:harness_session` – `%{provider: String.t(), harness_session_id:
      String.t(), lost: boolean, cut: non_neg_integer}`: a harness turn
      started a fresh harness session. `lost` is true when the turn asked
      to resume another one that the harness no longer has; `cut` is the
      number of transcript messages the provider left out of what it sent
      to the fresh session
  """

  @enforce_keys [:type, :session_id, :turn_id, :seq, :data]
  defstruct [:type, :session_id, :turn_id, :seq, :data]

  @type type ::
          :agent_start
          | :agent_end
          | :turn_start
          | :turn_end
          | :message_start
          | :message_update
          | :message_end
          | :tool_execution_start
          | :tool_execution_end
          | :queue_update
          | :model_change
          | :harness_session

  @type t :: %__MODULE__{
          type: type(),
          session_id: String.t(),
          turn_id: String.t() | nil,
          seq: pos_integer(),
          data: map()
        }
end
