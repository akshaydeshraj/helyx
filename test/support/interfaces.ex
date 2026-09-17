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

defmodule Helyx.Test.NoInterface do
  @moduledoc false
  def name, do: "none"
end

defmodule Helyx.Test.ProviderTwin do
  @moduledoc false
  # A second provider with the same id as Helyx.Test.Provider.
  @behaviour Helyx.Provider

  @impl true
  def id, do: "test"

  @impl true
  def stream(_model, _context, _opts), do: {:ok, []}
end

defmodule Helyx.Test.Provider do
  @moduledoc false
  # A provider whose model name selects a stream shape, so session tests can
  # exercise streams that end badly.
  #
  #   "ok"         one delta, then done, after a short pause
  #   "empty"      an empty stream, no terminal event
  #   "crash"      one delta, then the stream raises
  #   "overrun"    done, then another delta that must be ignored
  #   "blocks"     thinking, text, and a tool call, then done
  #   "garbage"    one event that is not a stream event
  #   "wide"       a delta tuple with an extra element
  @behaviour Helyx.Provider

  @impl true
  def id, do: "test"

  @impl true
  def stream("ok", _context, _opts) do
    {:ok, Stream.map([{:text_delta, "ok"}, done()], &tap(&1, fn _ -> Process.sleep(50) end))}
  end

  def stream("empty", _context, _opts), do: {:ok, []}

  def stream("crash", _context, _opts) do
    {:ok, Stream.concat([{:text_delta, "so far"}], Stream.map([1], fn _ -> raise "boom" end))}
  end

  def stream("blocks", _context, _opts) do
    call = %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}

    {:ok,
     [
       {:thinking_delta, "hm"},
       {:thinking_delta, "m"},
       {:text_delta, "Listing"},
       {:text_delta, "."},
       {:tool_call, call},
       done()
     ]}
  end

  def stream("garbage", _context, _opts), do: {:ok, [{:text_delta, 42}]}
  def stream("wide", _context, _opts), do: {:ok, [{:text_delta, "hello", :extra}]}

  def stream("overrun", _context, _opts) do
    {:ok, [{:text_delta, "kept"}, done(), {:text_delta, " dropped"}]}
  end

  defp done, do: {:done, %{stop_reason: :end_turn, usage: %{}}}
end
