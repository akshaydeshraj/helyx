defmodule Helyx.Session.Queues do
  @moduledoc false
  # The steer and follow-up queues of a session, each in arrival order. Each
  # queue holds at most 32 entries. `push/3` is the only way in, so no queue
  # ever holds more. The session emits `:queue_update` for every change.

  @limit 32

  defstruct steers: [], follow_ups: []

  @type key :: :steers | :follow_ups
  @type t :: %__MODULE__{steers: [String.t()], follow_ups: [String.t()]}

  @spec push(t(), key(), String.t()) :: {:ok, t()} | {:error, :queue_full}
  def push(%__MODULE__{} = queues, key, text) when key in [:steers, :follow_ups] do
    entries = Map.fetch!(queues, key)

    if length(entries) < @limit,
      do: {:ok, Map.put(queues, key, entries ++ [text])},
      else: {:error, :queue_full}
  end

  # Every queued text, steers first, and the empty queues.
  @spec drain(t()) :: {[String.t()], t()}
  def drain(%__MODULE__{steers: steers, follow_ups: follow_ups}),
    do: {steers ++ follow_ups, %__MODULE__{}}

  # The queued steers, and the queues without them.
  @spec drain_steers(t()) :: {[String.t()], t()}
  def drain_steers(%__MODULE__{steers: steers} = queues), do: {steers, %{queues | steers: []}}

  @spec counts(t()) :: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
  def counts(%__MODULE__{steers: steers, follow_ups: follow_ups}),
    do: %{steers: length(steers), follow_ups: length(follow_ups)}
end
