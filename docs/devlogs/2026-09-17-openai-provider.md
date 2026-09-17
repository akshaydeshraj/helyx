# OpenAI model provider against OpenCode (ticket #7)

## Done

- `plugins/provider_openai`: `Helyx.Provider.OpenAI` speaks the OpenAI chat completions wire format with SSE streaming against the OpenCode gateways. The engine is one module; the plugins are the nested modules `OpenAI.Go` (`opencode-go/<model>`, `https://opencode.ai/zen/go/v1`) and `OpenAI.Zen` (`opencode/<model>`, `https://opencode.ai/zen/v1`), because `Provider.find/2` matches one id per plugin module.
- The API key comes from `OPENCODE_API_KEY`, read at call time. A missing key is `{:error, {:missing_env, ...}}` before any request. Every request carries the session id in `x-opencode-session`, which OpenCode Go requires per session.
- The provider returns a lazy stream: `Stream.flat_map` over one element runs the HTTP request when the session's turn Task consumes it, and the `Req` async body (`into: :self`) is itself enumerable, applies `receive_timeout` between chunks, and cancels the request when the consumer halts. A transport error mid-stream raises, which core turns into a failed turn (`{:task_exit, reason}`).
- SSE parsing buffers partial lines across chunks with one `:binary.split` pass. `data:` payloads decode with the stdlib `JSON`. `content` deltas become `text_delta`; `reasoning_content` or `reasoning` deltas become `thinking_delta`. Tool call fragments assemble by index — a delta without an index starts a new call when it carries an id and extends the last call otherwise — and the whole calls plus the `done` event (with `usage: %{input, output}`) emit at `[DONE]`.
- Failure paths: a non-2xx response is one `{:error, {:http_status, status, body}}` event; an in-stream `{"error": ...}` object is `{:error, {:api_error, ...}}`; a dropped stream emits no `done`, so the session fails the turn with `:stream_ended` and keeps no partial message; a chunk that does not parse and tool arguments that do not decode are error events.
- Tests stub with `Req.Test` and recorded SSE bodies; nothing touches the network. The plug is injected through the `:req_options` application env of `:helyx_provider_openai`, set only in tests. The chunk-boundary and wire-shape edge cases run on the public `events/1` transform directly, because the plug adapter delivers one chunk per response.

## What broke

- The first transport was a hand-rolled `Stream.resource` with a bare `receive`, which swallowed the consuming process's other mailbox messages. Review replaced the whole loop with `Req.Response.Async`'s own `Enumerable`, which is selective, timed, and cancels on halt.
- Tool call deltas without an `"index"` all merged into one call, so a second call's arguments landed on the first call's id and name. The failure-path review reproduced it; the accumulator now implies an index from the id.

## Decisions taken without a ticket line

- Thinking blocks go back on assistant messages as `reasoning_content`. Kimi's thinking models need the reasoning of the tool-call loop replayed to keep their chain; the first cut dropped it and PR review caught the broken continuation.
- `finish_reason` maps `tool_calls` to `:tool_use`, `length` to `:max_tokens`, anything else to `:end_turn`.
- No session-seam test in this plugin: the session loop is covered by the Fake provider tests, which the provider seam composes with.
- `Helyx.Provider`'s moduledoc now names the opts keys the session passes (`:core`, `:session_id`, `:turn_id`), so providers stop guessing.

## Review

See `docs/reviews/2026-09-17-issue-7.md`.

## Next

- The manual IEx run against a live endpoint needs `OPENCODE_API_KEY`, which is not on this machine. To run it:

  ```elixir
  # OPENCODE_API_KEY=... iex -S mix (from plugins/provider_openai)
  {:ok, _} = Supervisor.start_link([{Helyx.Core, plugins: [Helyx.Provider.OpenAI.Go]}], strategy: :one_for_one)
  {:ok, s} = Helyx.Session.start(Helyx.Core, model: "opencode-go/kimi-k2")
  :ok = Helyx.Session.subscribe(s)
  :ok = Helyx.Session.prompt(s, "Say hello.")
  flush()
  ```
