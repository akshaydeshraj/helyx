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
    * `:message_update` – `%{delta: binary}`
    * `:message_end` – `%{message: Helyx.Message.t()}`
    * `:turn_end` – `%{message: Helyx.Message.t()}`
    * `:agent_end` – `%{stop_reason: atom}`
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

  @type t :: %__MODULE__{
          type: type(),
          session_id: String.t(),
          turn_id: String.t() | nil,
          seq: pos_integer(),
          data: map()
        }
end
