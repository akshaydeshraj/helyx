# The JSON-RPC protocol of `codex app-server`

Research for ticket #11 (Codex harness provider). Facts observed on 2026-09-25 from the unmodified Codex program, `codex-cli 0.155.0`, on macOS, signed in with ChatGPT (`codex login status` prints `Logged in using ChatGPT`). Sources: `codex app-server --help`, the schema that `codex app-server generate-json-schema --out <dir>` writes (without `--experimental`), and eight small runs with the model `gpt-6-luna`, the cheapest in `model/list`, driven by a Python script over stdio. The program is closed to Helyx and changes often, so the facts below are observations of one version, not a contract. Anything marked "not verified" was not run.

## Transport

- `codex app-server` with no option listens on stdio (`--listen stdio://` is the default). Each message is one JSON object on one line, in both directions. The server writes no `"jsonrpc"` key; it accepts requests that have one.
- Stderr carries the program's own log lines (with ANSI colour codes), for example `ERROR codex_core::session: failed to record rollout items`. Stdout carries only protocol lines.
- **End of file on stdin ends the program with exit status 0.** Every run below ended that way after its last response.
- The user's own configuration is active: `~/.codex/config.toml`, its MCP servers (`mcpServer/startupStatus/updated` notifications), and its hooks (`hook/started`, `hook/completed`).

## Handshake

1. Request `initialize` with `{"clientInfo": {"name": ..., "version": ...}}`. The result has `userAgent`, `codexHome`, `platformFamily`, and `platformOs`.
2. Notification `initialized` (no params).

## Threads

- `thread/start` takes `cwd`, `model`, `approvalPolicy`, `sandbox`, and more, all optional. The result is `{"thread": {...}}` with `thread.id` (a UUIDv7 string, 36 bytes), `thread.path` (the rollout file under `~/.codex/sessions/`), `model`, and the resolved `cwd`. A relative `cwd` is resolved against the program's working directory. A `thread/started` notification with the same thread follows. The result line was 1,830 bytes.
- `thread/resume` takes `threadId` and the same overrides. With `"excludeTurns": true` the result has the thread without its turns; without it, `thread.turns` holds the whole history.
- **A lost thread.** `thread/resume` with a UUID that names no thread gives an error response and nothing else: `{"error":{"code":-32600,"message":"no rollout found for thread id <id>"},"id":2}`. The program keeps running, so a `thread/start` on the same connection works.
- **A killed program leaves a resumable thread.** A run got `SIGTERM` to its process group while the model ran `sleep 30`; the program logged `failed to record rollout items: thread ... not found` and exited. A new program resumed the thread by id, and the model knew the code word given in the killed turn's prompt.

## Replay: `thread/inject_items`

`thread/inject_items` is in the stable schema (not `--experimental`): `{"threadId": ..., "items": [...]}`, where `items` are "raw Responses API items to append to the thread's model-visible history". The result is `{}`. It makes no model call and no item notifications.

Verified on a fresh thread, before its first turn, with these items:

```json
{"type":"message","role":"user","content":[{"type":"input_text","text":"Remember the code word PELICAN."}]}
{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Noted: the code word is PELICAN."}]}
{"type":"function_call","call_id":"toolu_01ABC","name":"Read","arguments":"{\"path\": \"notes.txt\"}"}
{"type":"function_call_output","call_id":"toolu_01ABC","output":"the file says: BLUE HORSE"}
{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I read notes.txt."}]}
```

The next `turn/start` answered `Code word: PELICAN; notes.txt said: BLUE HORSE.` with no tool run. So user text, assistant text, and a call with its output all reach the model, and a call to a tool that the thread does not have (`Read`) is accepted in history.

The model API checks the injected items only when a turn sends them, and the thread keeps them: **a bad item fails every later turn of that thread**. Observed limits, each from a `turn/completed` with `status: "failed"` and the API's `invalid_request_error`:

- `name` of a `function_call` must match `^[a-zA-Z0-9_-]+$`: `mcp/server.tool` was rejected.
- `call_id` has at most 64 characters: 100 was rejected, 64 was accepted. `call.a/b:1` (dots, a slash, a colon) was accepted.

Not verified: the length limit of `name`, a `call_id` with non-ASCII characters, image content, and a size limit of the injected history.

## Turns

- `turn/start` takes `threadId` and `input`, a list of `{"type":"text","text":...}` (images and more exist). The result is `{"turn": {"id": ..., "status": "inProgress", ...}}`.
- Notifications of one turn, in order: `turn/started`; `item/started` and `item/completed` of a `userMessage` (the prompt); then per model output `item/started`, deltas, `item/completed`; `thread/tokenUsage/updated` after each model call; `turn/completed` last. Every one carries `threadId` and `turnId`.
- `turn/completed` has `turn.status`: `completed`, `interrupted`, or `failed`, and `turn.error` (`{"message": ..., "codexErrorInfo": ...}`) when failed. A failed turn is preceded by an `error` notification with the same error and `"willRetry": false`.
- `thread/tokenUsage/updated` has `tokenUsage.last` and `tokenUsage.total`, each `{totalTokens, inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens}`.

### Items

`item.type` values in the schema: `userMessage`, `hookPrompt`, `agentMessage`, `functionCallOutput`, `plan`, `reasoning`, `commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, `collabAgentToolCall`, `subAgentActivity`, `webSearch`, `imageView`, `sleep`, `imageGeneration`, `enteredReviewMode`, `exitedReviewMode`, `contextCompaction`. Observed in runs: `userMessage`, `reasoning`, `agentMessage`, `commandExecution`.

- `agentMessage`: `item/started` with `text: ""`, then `item/agentMessage/delta` notifications (`{"itemId": ..., "delta": "Code"}`), then `item/completed` with the whole `text`. `phase` was `commentary` for text before a tool call and `final_answer` for the last text.
- `reasoning`: `item/started` and `item/completed` with empty `summary` and `content` lists for this model. The schema has `item/reasoning/summaryTextDelta` and `item/reasoning/textDelta` (`{"itemId", "delta", ...}`); neither was observed.
- `commandExecution`: `item/started` with `command` (`/bin/zsh -lc 'echo hi > out.txt && cat out.txt'`), `cwd`, `status: "inProgress"`, and `processId` (an id of the program, not an OS pid); `item/completed` with `status: "completed"`, `aggregatedOutput` (`"hi\n"`), and `exitCode`. No `item/commandExecution/outputDelta` was observed. The status enum is `inProgress`, `completed`, `failed`, `declined`; `fileChange` has the same, `mcpToolCall` and `dynamicToolCall` have no `declined`.

## Interrupt

`turn/interrupt` with `threadId` and `turnId`, sent while the model ran `sleep 30`: the result `{}` and `turn/completed` with `status: "interrupted"` arrived within 1 ms of each other, less than 1 s after the request. The running `commandExecution` got no `item/completed`.

## Processes

The program on `PATH` is a Node wrapper (`~/.bun/bin/codex`) that runs the native binary as its child in the same process group. The native binary starts every command, and its helper processes (`node_repl`, `codex-code-mode-host`), **each in a process group of its own**.

- `SIGTERM` to the wrapper's group while `sleep 30` ran: 0.5 s later no process of the tree was left. The program ends its commands itself.
- `SIGKILL` to the same group: `sleep 30` survived with parent 1 in its own group. The helpers ended.

## Approvals

With `"approvalPolicy": "never"` and `"sandbox": "danger-full-access"` on `thread/start` and `thread/resume`, the runs above ran commands and wrote files with no server request. The schema lists these server requests: `item/commandExecution/requestApproval` and `item/fileChange/requestApproval` (result `{"decision": "accept" | "acceptForSession" | "decline" | "cancel" | ...}`), `item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `item/tool/call`, `account/chatgptAuthTokens/refresh`, `attestation/generate`, and the v1 `applyPatchApproval` and `execCommandApproval`. None arrived in these runs. Not verified: what the program does with a JSON-RPC error answer to a server request (fail the item, fail the turn, or wait).

## Sizes

No limit is documented for a line. The largest lines in these runs were the `thread/start` result and the `thread/started` notification, under 2,000 bytes each. `thread/resume` without `excludeTurns` returns the whole history in one line (not measured).
