defmodule Helyx.Session.Snapshot do
  @moduledoc """
  The state of a session at one event, as `Helyx.Session.subscribe/1`
  returns it.

    * `seq` – the seq of the last event sent before the snapshot, 0 if none.
      A client drops each later event with a `seq` at or below it.
    * `messages` – the transcript, oldest first.
    * `turn` – nil, or the running turn: its `id`, the assistant message
      so far as `partial` (nil before the first stream event), and in
      `running` the ids of the tool calls that have started and have no
      result yet.
    * `model` – the session's `provider/model` ref.
    * `queue` – the counts of the queued steers and follow-ups.
  """

  @enforce_keys [:seq, :messages, :turn, :model, :queue]
  defstruct [:seq, :messages, :turn, :model, :queue]

  @type turn :: %{id: String.t(), partial: Helyx.Message.t() | nil, running: [String.t()]}

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          messages: [Helyx.Message.t()],
          turn: turn() | nil,
          model: String.t(),
          queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
        }
end
