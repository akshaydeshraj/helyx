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

defmodule Helyx.Test.ModelContext do
  @moduledoc false
  # Marks the context so a provider can show it was built.
  @behaviour Helyx.ModelContext

  @impl true
  def build(context, opts), do: %{context | system: "built for #{opts[:cwd]}"}
end

defmodule Helyx.Test.ModelContextTwin do
  @moduledoc false
  @behaviour Helyx.ModelContext

  @impl true
  def build(context, _opts), do: context
end

defmodule Helyx.Test.Compaction do
  @moduledoc false
  # Appends to the system prompt so tests see it ran after model context.
  @behaviour Helyx.Compaction

  @impl true
  def compact(context, _opts), do: %{context | system: "#{context.system}, compacted"}
end

defmodule Helyx.Test.CompactionTwin do
  @moduledoc false
  @behaviour Helyx.Compaction

  @impl true
  def compact(context, _opts), do: context
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
  #   "overrun"    a delta, done, then a raise if pulled further
  #   "blocks"     thinking, text, and a tool call, then done; text after the result
  #   "error_tail" an error event, then a raise if pulled further
  #   "garbage"    one event that is not a stream event
  #   "wide"       a delta tuple with an extra element
  #   "tools"      the names of the tools in the context, as text
  #   "system"     the system prompt in the context, as text
  #   "loop"       calls upcase and then a missing tool; after the results,
  #                echoes them as text
  #   "serial"     three calls to the slow tool, then echoes the results
  #   "bad_call"   a tool call whose name is not a string
  #   "kill"       calls the kill tool, then echoes the result as text
  #   "hang"       one delta, then the stream blocks forever
  #   "abort"      three calls to the slow tool that sleep for a minute;
  #                after the results, echoes them as text
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
        {:ok, echo_results(messages)}

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

  def stream("system", %Helyx.Context{system: system}, _opts) do
    {:ok, [{:text_delta, system || "no system"}, done()]}
  end

  def stream("crash", _context, _opts) do
    {:ok, raise_after([{:text_delta, "so far"}], "boom")}
  end

  def stream("blocks", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} -> {:ok, [{:text_delta, "done"}, done()]}
      _ -> {:ok, blocks()}
    end
  end

  def stream("serial", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} ->
        {:ok, echo_results(messages)}

      _ ->
        {:ok, slow_calls([{"1", 60}, {"2", 30}, {"3", 0}]) ++ [done()]}
    end
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

  def stream("hang", _context, _opts) do
    {:ok,
     Stream.concat(
       [{:text_delta, "so far"}],
       Stream.repeatedly(fn -> Process.sleep(:infinity) end)
     )}
  end

  def stream("abort", %Helyx.Context{messages: messages}, _opts) do
    if Enum.any?(messages, &(&1.role == :tool_result)) do
      {:ok, echo_results(messages)}
    else
      {:ok, slow_calls(for id <- ["1", "2", "3"], do: {id, 60_000}) ++ [done()]}
    end
  end

  def stream("error_tail", _context, _opts) do
    {:ok, raise_after([{:error, :overloaded}], "pulled past the error")}
  end

  def stream("garbage", _context, _opts), do: {:ok, [{:text_delta, 42}]}
  def stream("wide", _context, _opts), do: {:ok, [{:text_delta, "hello", :extra}]}

  def stream("overrun", _context, _opts) do
    {:ok, raise_after([{:text_delta, "kept"}, done()], "pulled past done")}
  end

  # A lazy tail that raises when pulled, so a consumer that reads past
  # `events` fails its test instead of passing silently.
  defp raise_after(events, message) do
    Stream.concat(events, Stream.map([1], fn _ -> raise message end))
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

  defp slow_calls(pairs) do
    for {id, ms} <- pairs do
      {:tool_call,
       %Helyx.Message.ToolCall{id: id, name: "slow", arguments: %{"ms" => ms, "text" => id}}}
    end
  end

  # The tool result texts so far, joined with "|", then done.
  defp echo_results(messages) do
    results = for %{role: :tool_result} = m <- messages, do: Helyx.Message.text(m)
    [{:text_delta, Enum.join(results, "|")}, done()]
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
  # run/2 never returns; the brutal kill is the point.
  @dialyzer {:nowarn_function, run: 2}
  @impl true
  def run(_args, _cwd), do: Process.exit(self(), :kill)
end

defmodule Helyx.Test.Tool.Slow do
  @moduledoc false
  # Sleeps `ms` and returns `text`, so call order and finish order can differ.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def description, do: "Sleeps, then echoes."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(%{"ms" => ms, "text" => text}, _cwd) do
    Process.sleep(ms)
    {:ok, text}
  end
end
