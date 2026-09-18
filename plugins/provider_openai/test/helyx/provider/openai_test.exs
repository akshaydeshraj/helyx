defmodule Helyx.Provider.OpenAITest do
  # Provider seam: call stream/3 on the plugin modules with Req's test adapter
  # and recorded response bodies. Nothing here touches the network. The
  # session loop above this seam is covered by the Fake provider tests.
  # Not async: the tests mutate OPENCODE_API_KEY and the :req_options app env.
  use ExUnit.Case, async: false

  alias Helyx.Provider.OpenAI

  setup do
    System.put_env("OPENCODE_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("OPENCODE_API_KEY") end)
  end

  defp sse(chunks) do
    Enum.map_join(chunks, fn
      chunk when is_binary(chunk) -> "data: #{chunk}\n\n"
      chunk -> "data: #{JSON.encode!(chunk)}\n\n"
    end)
  end

  defp delta(delta, finish \\ nil) do
    %{choices: [%{delta: delta, finish_reason: finish}]}
  end

  defp plug(fun) do
    Application.put_env(:helyx_provider_openai, :req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:helyx_provider_openai, :req_options) end)
  end

  defp stub(events) do
    test = self()

    plug(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, JSON.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse(events))
    end)
  end

  test "opencode-go and opencode refs route to the two plugins" do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [OpenAI.Go, OpenAI.Zen]})

    assert {:ok, OpenAI.Go} = Helyx.Provider.find(core, "opencode-go")
    assert {:ok, OpenAI.Zen} = Helyx.Provider.find(core, "opencode")
  end

  test "a streamed text response yields deltas, thinking, usage, and done" do
    stub([
      delta(%{role: "assistant", content: ""}),
      delta(%{reasoning_content: "hmm"}),
      delta(%{content: "Hel"}),
      delta(%{content: "lo"}),
      delta(%{}, "stop"),
      %{choices: [], usage: %{prompt_tokens: 12, completion_tokens: 3}},
      "[DONE]"
    ])

    context = %Helyx.Context{system: "Be brief.", messages: [Helyx.Message.user("hi")]}
    opts = [session_id: "s123", turn_id: "t1"]

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, opts)

    assert Enum.to_list(stream) == [
             {:thinking_delta, "hmm"},
             {:text_delta, "Hel"},
             {:text_delta, "lo"},
             {:done, %{stop_reason: :end_turn, usage: %{input: 12, output: 3}}}
           ]

    assert_received {:request, conn, body}
    assert conn.host == "opencode.ai"
    assert conn.request_path == "/zen/go/v1/chat/completions"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
    assert Plug.Conn.get_req_header(conn, "x-opencode-session") == ["s123"]

    assert body["model"] == "kimi-k2"
    assert body["stream"] == true
    assert body["stream_options"] == %{"include_usage" => true}

    assert body["messages"] == [
             %{"role" => "system", "content" => "Be brief."},
             %{"role" => "user", "content" => "hi"}
           ]
  end

  test "reasoning is thinking too, and a non-string field emits nothing" do
    stub([
      delta(%{reasoning: "why"}),
      delta(%{content: 42}),
      delta(%{reasoning_content: %{"a" => 1}}),
      delta(%{content: "ok"}, "stop"),
      "[DONE]"
    ])

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s", turn_id: "t")

    assert Enum.to_list(stream) == [
             {:thinking_delta, "why"},
             {:text_delta, "ok"},
             {:done, %{stop_reason: :end_turn, usage: %{}}}
           ]
  end

  test "a streamed tool call is assembled from deltas into one block" do
    stub([
      delta(%{content: "Listing."}),
      delta(%{
        tool_calls: [
          %{index: 0, id: "call_1", type: "function", function: %{name: "bash", arguments: ""}}
        ]
      }),
      delta(%{tool_calls: [%{index: 0, function: %{arguments: ~s({"comm)}}]}),
      delta(%{tool_calls: [%{index: 0, function: %{arguments: ~s(and": "ls"})}}]}),
      delta(%{}, "tool_calls"),
      "[DONE]"
    ])

    call = %Helyx.Message.ToolCall{id: "call_0", name: "bash", arguments: %{"command" => "pwd"}}

    context = %Helyx.Context{
      messages: [
        Helyx.Message.user("list the files"),
        %Helyx.Message{
          role: :assistant,
          content: [
            %Helyx.Message.Thinking{thinking: "I should list."},
            %Helyx.Message.Text{text: "First."},
            call
          ]
        },
        Helyx.Message.tool_result(call, {:ok, "/repo"})
      ],
      tools: [%{name: "bash", description: "Runs a command.", parameters: %{"type" => "object"}}]
    }

    assert {:ok, stream} = OpenAI.Zen.stream("gpt-5", context, [])

    assert Enum.to_list(stream) == [
             {:text_delta, "Listing."},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]

    assert_received {:request, conn, body}
    assert conn.request_path == "/zen/v1/chat/completions"

    assert body["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "bash",
                 "description" => "Runs a command.",
                 "parameters" => %{"type" => "object"}
               }
             }
           ]

    assert body["messages"] == [
             %{"role" => "user", "content" => "list the files"},
             %{
               "role" => "assistant",
               "content" => "First.",
               "reasoning_content" => "I should list.",
               "tool_calls" => [
                 %{
                   "id" => "call_0",
                   "type" => "function",
                   "function" => %{"name" => "bash", "arguments" => ~s({"command":"pwd"})}
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "call_0", "content" => "/repo"}
           ]
  end

  defmodule BinaryTool do
    @moduledoc false
    # A tool whose result is not valid UTF-8, so the composition test below
    # can show the hands deliver text the request encoder accepts.
    @behaviour Helyx.Tool

    @impl true
    def name, do: "binary"
    @impl true
    def description, do: "Returns invalid bytes."
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def run(_args, _cwd), do: {:ok, <<"a", 255, "b">>}
  end

  test "a tool result with invalid bytes from the hands encodes and sends" do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [OpenAI.Go, BinaryTool]})
    {:ok, hands} = Helyx.Hands.start_link(core: core, cwd: File.cwd!(), session: self())

    call = %Helyx.Message.ToolCall{id: "call_1", name: "binary", arguments: %{}}
    :ok = Helyx.Hands.run(hands, "t1", call)
    assert_receive {:tool_result, "t1", "call_1", result}, 1_000

    stub([delta(%{content: "ok"}, "stop"), "[DONE]"])

    context = %Helyx.Context{
      messages: [
        Helyx.Message.user("go"),
        %Helyx.Message{role: :assistant, content: [call]},
        Helyx.Message.tool_result(call, result)
      ]
    }

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert List.last(Enum.to_list(stream)) == {:done, %{stop_reason: :end_turn, usage: %{}}}

    assert_received {:request, _conn, body}

    assert List.last(body["messages"]) ==
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "a�b"}
  end

  test "a non-2xx response yields one error event with the body" do
    plug(&Plug.Conn.send_resp(&1, 401, ~s({"error": "bad key"})))
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert Enum.to_list(stream) == [{:error, {:http_status, 401, ~s({"error": "bad key"})}}]
  end

  test "a transport error at connect is an error event" do
    plug(&Req.Test.transport_error(&1, :econnrefused))
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert [{:error, %Req.TransportError{reason: :econnrefused}}] = Enum.to_list(stream)
  end

  test "a stream that drops before [DONE] yields no done event" do
    stub([delta(%{content: "Hel"}), delta(%{}, "stop")])
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert Enum.to_list(stream) == [{:text_delta, "Hel"}]
  end

  test "an in-stream error object is an error event" do
    chunks = [sse([%{error: %{message: "overloaded"}}])]

    assert Enum.to_list(OpenAI.events(chunks)) ==
             [{:error, {:api_error, %{"message" => "overloaded"}}}]
  end

  test "tool calls without indexes stay separate calls" do
    chunks = [
      sse([
        delta(%{tool_calls: [%{id: "c1", function: %{name: "read", arguments: ~s({"a": 1})}}]}),
        delta(%{tool_calls: [%{id: "c2", function: %{name: "bash", arguments: ~s({"b": 2})}}]}),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert Enum.to_list(OpenAI.events(chunks)) == [
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c1", name: "read", arguments: %{"a" => 1}}},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c2", name: "bash", arguments: %{"b" => 2}}},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]
  end

  test "a missing api key is an error before any request" do
    System.delete_env("OPENCODE_API_KEY")
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:error, {:missing_env, "OPENCODE_API_KEY"}} =
             OpenAI.Go.stream("kimi-k2", context, [])
  end

  # The transport hands the parser arbitrary chunks. Req's test adapter sends
  # one chunk per response, so the reassembly cases run on events/1 directly.
  test "a data line split across chunks is reassembled and blank data is skipped" do
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"con",
      "tent\":\"Hi\"}}]}\n\ndata:\n\ndata: {\"choices\":[{\"delta\":{},",
      "\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    ]

    assert Enum.to_list(OpenAI.events(chunks)) == [
             {:text_delta, "Hi"},
             {:done, %{stop_reason: :end_turn, usage: %{}}}
           ]
  end

  test "a chunk that does not parse is an error event" do
    assert Enum.to_list(OpenAI.events(["data: {oops\n\n"])) ==
             [{:error, {:bad_chunk, "{oops"}}]
  end

  for chunk <- [
        ~s({"choices":[{"delta":"oops"}]}),
        ~s({"choices":{"a":1}}),
        ~s({"choices":[42]}),
        ~s([1,2]),
        ~s({"choices":[{"delta":{"tool_calls":"x"}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"function":"x"}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"function":{"arguments":{}}}]}}]})
      ] do
    test "a chunk with the wrong shape is an error event: #{chunk}" do
      assert Enum.to_list(OpenAI.events([sse([unquote(chunk)])])) ==
               [{:error, {:bad_chunk, unquote(chunk)}}]
    end
  end

  # The [DONE] arrives in a later chunk so the test covers both halts: the
  # line one inside the bad chunk and the chunk one that cancels the request.
  test "a bad chunk ends the stream after the events before it" do
    chunks = [
      sse([
        delta(%{content: "Hi"}),
        delta(%{tool_calls: [%{index: 0, id: "c1", function: %{name: "bash", arguments: "{"}}]}),
        ~s({"choices":[42]}),
        delta(%{}, "stop")
      ]),
      sse(["[DONE]"])
    ]

    assert Enum.to_list(OpenAI.events(chunks)) ==
             [{:text_delta, "Hi"}, {:error, {:bad_chunk, ~s({"choices":[42]})}}]
  end
end
