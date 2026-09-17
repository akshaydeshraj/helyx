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
  #   "blocks"     thinking, text, and a tool call, then done; text after the result
  #   "garbage"    one event that is not a stream event
  #   "wide"       a delta tuple with an extra element
  #   "tools"      the names of the tools in the context, as text
  #   "loop"       calls upcase and then a missing tool; after the results,
  #                echoes them as text
  #   "dup_ids"    two tool calls with one id
  #   "bad_call"   a tool call whose name is not a string
  #   "kill"       calls the kill tool, then echoes the result as text
  @behaviour Helyx.Provider

  @impl true
  def id, do: "test"

  @impl true
  def stream("ok", _context, _opts) do
    {:ok, Stream.map([{:text_delta, "ok"}, done()], &tap(&1, fn _ -> Process.sleep(50) end))}
  end

  def stream("empty", _context, _opts), do: {:ok, []}

  def stream("loop", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} ->
        results = for %{role: :tool_result} = m <- messages, do: Helyx.Message.text(m)
        {:ok, [{:text_delta, Enum.join(results, "|")}, done()]}

      _ ->
        {:ok,
         [
           {:tool_call,
            %Helyx.Message.ToolCall{id: "c1", name: "upcase", arguments: %{"text" => "hi"}}},
           {:tool_call, %Helyx.Message.ToolCall{id: "c2", name: "nope", arguments: %{}}},
           {:done, %{stop_reason: :tool_use, usage: %{}}}
         ]}
    end
  end

  def stream("tools", %Helyx.Context{tools: tools}, _opts) do
    {:ok, [{:text_delta, Enum.map_join(tools, ",", & &1.name)}, done()]}
  end

  def stream("crash", _context, _opts) do
    {:ok, Stream.concat([{:text_delta, "so far"}], Stream.map([1], fn _ -> raise "boom" end))}
  end

  def stream("blocks", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} -> {:ok, [{:text_delta, "done"}, done()]}
      _ -> {:ok, blocks()}
    end
  end

  def stream("dup_ids", _context, _opts) do
    call = %Helyx.Message.ToolCall{id: "same", name: "upcase", arguments: %{"text" => "a"}}
    {:ok, [{:tool_call, call}, {:tool_call, call}, done()]}
  end

  def stream("bad_call", _context, _opts) do
    {:ok, [{:tool_call, %Helyx.Message.ToolCall{id: "c", name: %{}, arguments: %{}}}]}
  end

  def stream("kill", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} = m ->
        {:ok, [{:text_delta, Helyx.Message.text(m)}, done()]}

      _ ->
        {:ok,
         [{:tool_call, %Helyx.Message.ToolCall{id: "k", name: "kill", arguments: %{}}}, done()]}
    end
  end

  def stream("garbage", _context, _opts), do: {:ok, [{:text_delta, 42}]}
  def stream("wide", _context, _opts), do: {:ok, [{:text_delta, "hello", :extra}]}

  def stream("overrun", _context, _opts) do
    {:ok, [{:text_delta, "kept"}, done(), {:text_delta, " dropped"}]}
  end

  defp blocks do
    call = %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}

    [
      {:thinking_delta, "hm"},
      {:thinking_delta, "m"},
      {:text_delta, "Listing"},
      {:text_delta, "."},
      {:tool_call, call},
      done()
    ]
  end

  defp done, do: {:done, %{stop_reason: :end_turn, usage: %{}}}
end

defmodule Helyx.Test.Tool.Upcase do
  @moduledoc false
  @behaviour Helyx.Tool

  @impl true
  def name, do: "upcase"
  @impl true
  def description, do: "Upcases text."
  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
  @impl true
  def run(%{"text" => text}, _cwd), do: {:ok, String.upcase(text)}
end

defmodule Helyx.Test.Tool.UpcaseTwin do
  @moduledoc false
  # A second tool with the same name as Helyx.Test.Tool.Upcase.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "upcase"
  @impl true
  def description, do: "Upcases text."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(_args, _cwd), do: {:ok, "twin"}
end

defmodule Helyx.Test.Tool.Kill do
  @moduledoc false
  # A tool whose Task dies without returning.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "kill"
  @impl true
  def description, do: "Kills its own Task."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(_args, _cwd), do: Process.exit(self(), :kill)
end
