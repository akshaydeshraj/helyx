defmodule Helyx.Test.Single do
  @moduledoc false
  use Helyx.Interface, mode: :single

  @callback name() :: String.t()
end

defmodule Helyx.Test.Multi do
  @moduledoc false
  use Helyx.Interface, mode: :multi

  @callback name() :: String.t()
end

defmodule Helyx.Test.Required do
  @moduledoc false
  use Helyx.Interface, mode: :single, required: true

  @callback name() :: String.t()
end

defmodule Helyx.Test.SingleA do
  @moduledoc false
  @behaviour Helyx.Test.Single
  def name, do: "single-a"
end

defmodule Helyx.Test.SingleB do
  @moduledoc false
  @behaviour Helyx.Test.Single
  def name, do: "single-b"
end

defmodule Helyx.Test.MultiA do
  @moduledoc false
  @behaviour Helyx.Test.Multi
  def name, do: "multi-a"
end

defmodule Helyx.Test.MultiB do
  @moduledoc false
  @behaviour Helyx.Test.Multi
  def name, do: "multi-b"
end

defmodule Helyx.Test.RequiredA do
  @moduledoc false
  @behaviour Helyx.Test.Required
  def name, do: "required-a"
end

defmodule Helyx.Test.NoInterface do
  @moduledoc false
  def name, do: "none"
end

defmodule Helyx.Test.Provider do
  @moduledoc false
  # A provider whose model name selects a stream shape, so session tests can
  # exercise streams that end badly.
  #
  #   "ok"        one delta, then done, after a short pause
  #   "empty"     an empty stream, no terminal event
  #   "late_exit" done, then the task exits abnormally
  @behaviour Helyx.Provider

  @impl true
  def id, do: "test"

  @impl true
  def stream("ok", _context, _opts) do
    {:ok, Stream.map([{:text_delta, "ok"}, done()], &tap(&1, fn _ -> Process.sleep(50) end))}
  end

  def stream("empty", _context, _opts), do: {:ok, []}

  def stream("late_exit", _context, _opts) do
    {:ok, Stream.concat([done()], Stream.map([1], fn _ -> exit(:late) end))}
  end

  defp done, do: {:done, %{stop_reason: :end_turn, usage: %{}}}
end
