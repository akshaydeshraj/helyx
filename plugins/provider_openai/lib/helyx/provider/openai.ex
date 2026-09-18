defmodule Helyx.Provider.OpenAI do
  @moduledoc """
  A model provider that speaks the OpenAI chat completions wire format with
  server-sent event streaming, against the OpenCode gateways.

  The engine lives here. The plugins are the nested modules, one per model
  ref prefix, each bound to one base URL:

    * `Helyx.Provider.OpenAI.Go`: `opencode-go/<model>`, OpenCode Go
    * `Helyx.Provider.OpenAI.Zen`: `opencode/<model>`, OpenCode Zen

  The API key comes from `OPENCODE_API_KEY`. Every request carries the
  session id in the `x-opencode-session` header so the gateway can track the
  session.
  """

  defmodule Go do
    @moduledoc "The OpenCode Go endpoint. See `Helyx.Provider.OpenAI`."
    @behaviour Helyx.Provider

    @impl true
    def id, do: "opencode-go"

    @impl true
    def stream(model, context, opts),
      do: Helyx.Provider.OpenAI.stream(model, context, opts, "https://opencode.ai/zen/go/v1")
  end

  defmodule Zen do
    @moduledoc "The OpenCode Zen endpoint. See `Helyx.Provider.OpenAI`."
    @behaviour Helyx.Provider

    @impl true
    def id, do: "opencode"

    @impl true
    def stream(model, context, opts),
      do: Helyx.Provider.OpenAI.stream(model, context, opts, "https://opencode.ai/zen/v1")
  end

  @env_var "OPENCODE_API_KEY"
  @receive_timeout 120_000

  @doc "The shared `stream/3` of the endpoint plugins. `base_url` selects the endpoint."
  @spec stream(String.t(), Helyx.Context.t(), keyword(), String.t()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(model, context, opts, base_url) do
    case System.fetch_env(@env_var) do
      {:ok, key} -> {:ok, events(chunks(request(model, context, opts, base_url, key)))}
      :error -> {:error, {:missing_env, @env_var}}
    end
  end

  # Request

  defp request(model, context, opts, base_url, key) do
    Req.new(
      [
        base_url: base_url,
        url: "/chat/completions",
        auth: {:bearer, key},
        headers: session_header(opts),
        json: body(model, context),
        into: :self,
        receive_timeout: @receive_timeout
      ] ++ Application.get_env(:helyx_provider_openai, :req_options, [])
    )
  end

  defp session_header(opts) do
    case Keyword.get(opts, :session_id) do
      nil -> []
      id -> [{"x-opencode-session", id}]
    end
  end

  defp body(model, context) do
    body = %{
      model: model,
      stream: true,
      stream_options: %{include_usage: true},
      messages: messages(context)
    }

    case context.tools do
      [] -> body
      tools -> Map.put(body, :tools, Enum.map(tools, &tool/1))
    end
  end

  defp tool(spec) do
    %{
      type: "function",
      function: %{name: spec.name, description: spec.description, parameters: spec.parameters}
    }
  end

  defp messages(%Helyx.Context{system: system, messages: messages}) do
    system_message = if system, do: [%{role: "system", content: system}], else: []
    system_message ++ Enum.map(messages, &message/1)
  end

  defp message(%Helyx.Message{role: :user} = message),
    do: %{role: "user", content: Helyx.Message.text(message)}

  defp message(%Helyx.Message{role: :tool_result} = message) do
    %{role: "tool", tool_call_id: message.tool_call_id, content: Helyx.Message.text(message)}
  end

  # Thinking goes back as `reasoning_content`: Kimi's thinking models need
  # the reasoning of the tool-call loop replayed to keep their chain, and
  # models that do not think produce no thinking blocks to send.
  defp message(%Helyx.Message{role: :assistant} = message) do
    %{role: "assistant", content: Helyx.Message.text(message)}
    |> put_reasoning(message)
    |> put_tool_calls(message)
  end

  defp put_reasoning(wire, message) do
    case for %Helyx.Message.Thinking{thinking: thinking} <- message.content,
             into: "",
             do: thinking do
      "" -> wire
      reasoning -> Map.put(wire, :reasoning_content, reasoning)
    end
  end

  defp put_tool_calls(wire, message) do
    case for %Helyx.Message.ToolCall{} = call <- message.content, do: wire_call(call) do
      [] -> wire
      calls -> Map.put(wire, :tool_calls, calls)
    end
  end

  defp wire_call(call) do
    %{
      id: call.id,
      type: "function",
      function: %{name: call.name, arguments: JSON.encode!(call.arguments)}
    }
  end

  # Transport: one lazy stream of body chunks. The request runs when the
  # session's turn Task consumes the stream, so the async body lands in that
  # Task's mailbox. `Req.Response.Async` is enumerable, applies
  # `receive_timeout` between chunks, and cancels the request when the
  # consumer halts. A transport error while streaming raises, which fails the
  # turn as `{:task_exit, reason}`. Elements are binaries or one
  # `{:error, reason}` tuple.
  defp chunks(req) do
    Stream.flat_map([req], fn req ->
      case Req.post(req) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          body

        {:ok, %Req.Response{status: status} = resp} ->
          [{:error, {:http_status, status, drain(resp)}}]

        {:error, reason} ->
          [{:error, reason}]
      end
    end)
  end

  # The error body names the reason for a 401 or 429; without it the turn
  # error is just a number.
  defp drain(resp) do
    Enum.join(resp.body)
  rescue
    _ -> ""
  end

  # Wire events

  # The accumulator: `buffer` holds a partial SSE line across chunks, `calls`
  # assembles tool calls by index, `finish` and `usage` wait for `[DONE]`.
  @acc %{buffer: "", calls: %{}, finish: nil, usage: %{}}

  @doc """
  Transforms a stream of SSE body chunks into provider stream events.

  Public so tests can feed chunks split at arbitrary boundaries; the test
  adapter delivers each recorded body as one chunk.
  """
  @spec events(Enumerable.t()) :: Enumerable.t()
  def events(chunks) do
    Stream.transform(chunks, @acc, &handle/2)
  end

  # A bad chunk ended the stream; drop the rest and cancel the request.
  defp handle(_chunk, :halted), do: {:halt, :halted}

  defp handle({:error, reason}, acc), do: {[{:error, reason}], acc}

  # ponytail: buffer <> chunk re-copies the carried partial line per chunk;
  # make the buffer iodata if one huge data line ever shows up in profiles.
  defp handle(chunk, acc) when is_binary(chunk) do
    {lines, buffer} = split_lines(acc.buffer <> chunk)

    Enum.flat_map_reduce(lines, %{acc | buffer: buffer}, &line/2)
  end

  # Complete lines and the trailing partial one. SSE delimits with \n or \r\n.
  defp split_lines(data) do
    {partial, complete} = data |> :binary.split(["\r\n", "\n"], [:global]) |> List.pop_at(-1)
    {complete, partial}
  end

  defp line(_line, :halted), do: {:halt, :halted}
  defp line("data:" <> payload, acc), do: data(String.trim_leading(payload, " "), acc)
  defp line(_line, acc), do: {[], acc}

  defp data("[DONE]", acc), do: flush(acc)
  defp data("", acc), do: {[], acc}

  # A chunk that does not parse or has the wrong shape ends the stream with
  # one error event; nothing after it is processed, so no `done` follows.
  defp data(payload, acc) do
    with {:ok, chunk} <- JSON.decode(payload),
         true <- valid_chunk?(chunk) do
      chunk_events(chunk, acc)
    else
      _ -> {[{:error, {:bad_chunk, payload}}], :halted}
    end
  end

  # The one shape gate where a decoded chunk enters the parser. It rejects
  # every shape that could raise in the field walks below it or in the
  # iodata at flush, and a few degenerate ones that would not. A missing or
  # null field is fine, and so is a wrong-typed leaf the parser only copies
  # or drops, such as `content: 42`.
  defp valid_chunk?(%{} = chunk) do
    case chunk["choices"] do
      nil -> true
      choices when is_list(choices) -> valid_choice?(List.first(choices))
      _choices -> false
    end
  end

  defp valid_chunk?(_chunk), do: false

  defp valid_choice?(nil), do: true
  defp valid_choice?(%{} = choice), do: valid_delta?(choice["delta"])
  defp valid_choice?(_choice), do: false

  defp valid_delta?(nil), do: true

  defp valid_delta?(%{} = delta) do
    case delta["tool_calls"] do
      nil -> true
      calls when is_list(calls) -> Enum.all?(calls, &valid_call?/1)
      _calls -> false
    end
  end

  defp valid_delta?(_delta), do: false

  defp valid_call?(%{} = call) do
    case call["function"] do
      nil -> true
      # Non-binary argument fragments can raise later, at flush.
      %{} = function -> function["arguments"] == nil or is_binary(function["arguments"])
      _function -> false
    end
  end

  defp valid_call?(_call), do: false

  # A gateway reports a mid-stream failure as an error object in the data.
  defp chunk_events(%{"error" => error}, acc), do: {[{:error, {:api_error, error}}], acc}

  defp chunk_events(chunk, acc) do
    choice = List.first(chunk["choices"] || []) || %{}
    delta = choice["delta"] || %{}

    acc = %{
      acc
      | calls: Enum.reduce(delta["tool_calls"] || [], acc.calls, &add_call_delta/2),
        finish: choice["finish_reason"] || acc.finish,
        usage: chunk["usage"] || acc.usage
    }

    {delta_events(delta), acc}
  end

  # Thinking arrives as `reasoning_content` (DeepSeek style) or `reasoning`
  # (OpenRouter style); text as `content`. Empty and missing ones emit nothing.
  defp delta_events(delta) do
    for {kind, text} <- [
          thinking_delta: delta["reasoning_content"] || delta["reasoning"],
          text_delta: delta["content"]
        ],
        is_binary(text) and text != "",
        do: {kind, text}
  end

  # The first delta of a call usually carries the id and name; later ones
  # append argument fragments. Fragments of one call share an index. A delta
  # without an index starts the next call when it carries an id and extends
  # the last call otherwise. The id and name are taken from the first delta
  # that has them.
  defp add_call_delta(delta, calls) do
    function = delta["function"] || %{}
    arguments = function["arguments"] || ""

    Map.update(
      calls,
      Map.get_lazy(delta, "index", fn -> implied_index(delta, calls) end),
      %{id: delta["id"], name: function["name"] || "", arguments: [arguments]},
      fn call ->
        %{
          call
          | id: call.id || delta["id"],
            name: if(call.name == "", do: function["name"] || "", else: call.name),
            arguments: [call.arguments, arguments]
        }
      end
    )
  end

  defp implied_index(%{"id" => id}, calls) when is_binary(id), do: map_size(calls)
  defp implied_index(_delta, calls), do: max(map_size(calls) - 1, 0)

  # Emits the assembled tool calls and the terminal `done` at `[DONE]`. A
  # stream that dropped before `[DONE]` emits nothing here, so the session
  # fails the turn with `:stream_ended` and keeps no partial message.
  defp flush(%{finish: nil} = acc), do: {[], acc}

  defp flush(acc) do
    results = acc.calls |> Enum.sort() |> Enum.map(fn {_index, call} -> tool_call(call) end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {[{:error, reason}], acc}

      nil ->
        calls = Enum.map(results, fn {:ok, call} -> {:tool_call, call} end)
        done = {:done, %{stop_reason: stop_reason(acc.finish), usage: usage(acc.usage)}}
        {calls ++ [done], acc}
    end
  end

  defp tool_call(%{id: id, name: name, arguments: arguments}) do
    case IO.iodata_to_binary(arguments) do
      "" -> {:ok, %Helyx.Message.ToolCall{id: id, name: name, arguments: %{}}}
      json -> decode_arguments(id, name, json)
    end
  end

  defp decode_arguments(id, name, json) do
    case JSON.decode(json) do
      {:ok, arguments} when is_map(arguments) ->
        {:ok, %Helyx.Message.ToolCall{id: id, name: name, arguments: arguments}}

      _ ->
        {:error, {:bad_tool_arguments, name, json}}
    end
  end

  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason(_finish), do: :end_turn

  defp usage(%{} = usage) do
    for {wire, key} <- [{"prompt_tokens", :input}, {"completion_tokens", :output}],
        is_integer(usage[wire]),
        into: %{},
        do: {key, usage[wire]}
  end

  defp usage(_usage), do: %{}
end
