# The stream-json protocol of `claude -p`

Research for ticket #10 (Claude Code harness provider). Facts observed on 2026-09-19 from the unmodified Claude Code program, version `2.1.276`, on macOS, signed in with a subscription (`apiKeySource` is `none`). Source: `claude --help`, and four small `-p` runs with `--model haiku` in an empty directory with one text file. The program is closed source, so the facts below are observations of one version, not a contract. Anything marked "not verified" was not run.

## Command line

```text
claude -p --output-format stream-json --verbose [--include-partial-messages]
       [--input-format stream-json] [--model <model>] [--resume <session id>] [-- <prompt>]
```

- `--output-format stream-json` needs `--print` and `--verbose`.
- `--model` takes an alias (`haiku`, `sonnet`, `opus`) or a full name. The `init` line reports the full name (`claude-haiku-4-5-20251001` for `haiku`).
- Two ways to give the prompt, both verified:
  - As an argument. `claude -p ... -- "-Say ok again."` with stdin at `/dev/null` works, and `--` lets the prompt start with a dash. The argument is visible in `ps` and is bounded by the OS argument limit.
  - On stdin with `--input-format stream-json`: one JSON object per line, `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}`. The program runs the prompt and exits with status 0 when stdin reaches end of file.
- `--resume <session id>` continues a harness session. The run reports the same `session_id` as before, so the id is stable over resumes. `--fork-session` exists and gives a new id; not verified.
- `--session-id <uuid>` lets the caller choose the id; verified on `2.1.283` (see "Long-lived session and the control protocol").
- `--permission-mode` choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`. The `init` line reported `default` with no flag. In `-p` mode nobody can answer a permission prompt. The `Read` tool ran without a prompt. On `2.1.283`, `Write` in the default mode without a permission prompt tool is denied with a `system/permission_denied` line (see "Permission requests").
- The user's own hooks, plugins, skills, and `CLAUDE.md` files are active in a `-p` run. `--bare` turns them off, but it also turns off the OAuth login, so it cannot be used with a subscription.

## Output lines

Stdout is one JSON object per line. Every line has `type`, `session_id`, and `uuid`. Stderr was empty on the successful runs.

Observed order for one prompt that made one `Read` tool call, with `--include-partial-messages`:

| `type` / `subtype` | Count | Notes |
|---|---|---|
| `system` / `hook_started`, `hook_response` | 2 each | From the user's own hooks. A `hook_response` line carries the hook's stdout; one was 11,016 bytes. They come before `init` |
| `system` / `init` | 1 | `session_id`, `model`, `cwd`, `tools`, `permissionMode`, `apiKeySource`, `claude_code_version`, and more; 6,495 bytes |
| `system` / `status` | 1 per model call | `"status":"requesting"` |
| `rate_limit_event` | 1 | Position varies: after `init` in one run, before `result` in another |
| `stream_event` | many | Only with `--include-partial-messages`. `event` is a raw Anthropic Messages streaming event: `message_start`, `content_block_start`, `content_block_delta` (`text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta`), `content_block_stop`, `message_delta` (carries `stop_reason`), `message_stop` |
| `assistant` | 1 per content block | See below |
| `user` | 1 per tool result | See below |
| `result` | 1, last | See below |

Without `--include-partial-messages` the same run has no `stream_event` lines; all other lines are the same.

### `assistant`

`message` is an Anthropic Messages assistant message. One line carries exactly one content block. A model response with a thinking block and a tool call is two lines with the same `message.id`. `message.stop_reason` was `null` on every `assistant` line; the stop reason of a response appears only in the `message_delta` stream event. `message.usage` repeats on each line of one response. Top-level `parent_tool_use_id` is `null` for the main loop (a sub-agent sets it; not verified).

Blocks observed: `{"type":"thinking","thinking":"","signature":"..."}` (the thinking text was empty for this model, the signature was not), `{"type":"text","text":"..."}`, and `{"type":"tool_use","id":"toolu_...","name":"Read","input":{...},"caller":{"type":"direct"}}`.

With partial messages on, the `assistant` line of a block arrives after that block's last delta and before its `content_block_stop`.

### `user` (tool result)

```json
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_...","type":"tool_result","content":"1\thello file\n2\t"}]},"parent_tool_use_id":null,"session_id":"...","tool_use_result":{...}}
```

`content` was a string here. In the Messages format it can also be a list of text and image blocks, and the block can carry `is_error`; neither was observed. `tool_use_result` is a tool-specific structured copy. The tool result line arrived before the `message_delta` and `message_stop` stream events of the response that made the call.

### `result`

The last line. On success: `"subtype":"success"`, `"is_error":false`, `"result"` (the final text), `"stop_reason":"end_turn"`, `"num_turns"`, `"usage"` (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, and more), `"total_cost_usd"`, `"permission_denials"`, `"session_id"`. Exit status 0.

## A lost harness session

`claude -p ... --resume 11111111-2222-4333-8444-555555555555` (a valid UUID that names no session):

- Exit status 1.
- Stderr: `No conversation found with session ID: 11111111-2222-4333-8444-555555555555`.
- Stdout is one line only, with no `init` before it: `{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"11111111-...","errors":["No conversation found with session ID: 11111111-..."],...}`. The `session_id` is the one that was asked for, not a new one.
- No model call was made (`total_cost_usd` is 0). Nothing ran, so a second run without `--resume` repeats no work.

The only machine-readable sign is the text in `errors`. `error_during_execution` is a general subtype.

## Replay into a fresh session (2026-09-25)

Runs on 2026-09-25 with version `2.1.282`, `--model haiku`, `--input-format stream-json`, the input piped on stdin, and no `--resume`. Each run started a fresh harness session.

- **A `user` line starts a model call; an `assistant` line does not.** With the history `assistant` (text and a `tool_use`), `user` (the `tool_result`), `assistant` (text), `user` (the question), the first `user` line made a model call of its own (it answered `Ready. What's next?`, with its own `init` and `result`), and the question got a second call that knew the replayed history.
- **`"shouldQuery": false` on a `user` line records it with no model call.** Each such line gives one `init` line and one `result` line with `"subtype":"success"`, `"num_turns":0`, `"result":""`, and no `stop_reason`. The `assistant` lines give no output. The last `user` line, without the key, ran one model call that knew every replayed line: a user text, an earlier reply quoted word for word, a `tool_use` with its `tool_result`, and a `tool_result` with `"is_error": true`.
- **The `init` line repeats once per query of the run**, with the same `session_id`.
- **Tool ids.** `toolu_01AAAAAAAAAAAAAAAAAAAAAA` and `call_1` were both accepted as `tool_use` ids with their `tool_result`. The Messages API documents the pattern `^[a-zA-Z0-9_-]+$`; ids with other characters were not tried.
- **A leading `assistant` line** (the replay starts with an assistant reply, with no user line before it) was accepted, and the model used its text.
- **Thinking** was not replayed. The `thinking` blocks of these runs had empty text and a signature bound to the model that made them.

## Signals and resume (2026-09-25)

- **SIGTERM** to a run that had written `init` and started its reply ended it with exit status 143 and no `result` line.
- **A harness session whose run was killed can be resumed.** `--resume <id>` of that session ran the next prompt, and the model knew the prompt of the killed run (a code word given there).
- **A run killed during a tool call can be resumed** (`claude` 2.1.282, `--model haiku`, `bypassPermissions`). The run started `Bash` with `sleep 40`, got `SIGTERM` after its `tool_use` line and before a result, and `--resume <id>` ran the next prompt with no error. The model answered that the outcome of the command was unknown because the session ended before the result was recorded. So Claude Code closes an open tool call of a killed run by itself.
- **The `=` forms `--model=haiku` and `--resume=<id>` work** like the two-word forms. With a lost id, the output is the same as the lost case above: one `result` line, `error_during_execution`, `num_turns` 0, `errors` `["No conversation found with session ID: <id>"]`, and the same text on stderr.
- **`--permission-mode bypassPermissions`**: the `Write` tool ran with no prompt in a `-p` run through `Helyx.Provider.ClaudeCode`, and a `--resume=` turn after it knew the file's content.

## Sizes

No limit is documented for a line. A line holds a whole tool result or a whole hook output, so its size is set by the tool, not by the protocol. The largest line in these runs was 11,016 bytes. The program may write to stderr at any time.

## Not verified

- The `result` line of a run that hits an API error or a usage limit.
- Sub-agent lines (`parent_tool_use_id`), image tool results, and `is_error` tool results in the output (an `is_error` result in the replay was accepted).
- Tool ids with characters outside `[a-zA-Z0-9_-]` in the replay.

## Long-lived session and the control protocol (2026-09-26)

Runs on 2026-09-26 with version `2.1.283`, `--model haiku`, in empty temporary directories: eleven runs driven by a Python script over stdio. Sources: the Python Agent SDK `anthropics/claude-agent-sdk-python` tag `v0.2.160` (commit `36f95486ee9fc49d8ee1ed56811f07b5e8e23ac6`), files `_internal/transport/subprocess_cli.py`, `_internal/query.py`, `_internal/sdk_mcp_bridge.py`, `types.py`; and the TypeScript SDK `@anthropic-ai/claude-agent-sdk@0.3.283` (`sdk.d.ts`, `core.mjs`). "Verified" means a run on `2.1.283`. "Source" means one of these files.

### How the SDKs start the program (source)

- Always `--output-format stream-json --verbose --input-format stream-json`. **No `-p`.** The runs above also worked without `-p` (verified).
- `--permission-prompt-tool stdio` when the host answers permission requests (below). `--mcp-config <json>` for SDK MCP servers. `--resume=<id>` and `--session-id=<id>` always in the `=` form.
- Environment: `CLAUDE_CODE_ENTRYPOINT=sdk-py` (or `sdk-ts`), and `CLAUDECODE` removed.
- The Python SDK passes `--system-prompt ""` when the caller gives no prompt, so the SDK default is not the Claude Code prompt. A harness that wants the Claude Code prompt does not pass it.
- `--setting-sources ""` still loaded a claude.ai connector MCP server; `--strict-mcp-config` removed it (verified).

### One process, many turns (verified)

- One process takes many user lines on one stdin over time. Stdin stays open. Each turn writes `system/init` again, with the same `session_id`, and ends with its own `result` line.
- New `result` fields: `terminal_reason` (`completed`, `aborted_streaming`, `aborted_tools`), `result_index` (0, 1, 2, ... per process), and `queued_turn_count`. `usage` is for the turn. `total_cost_usd` and `modelUsage` add up over the process.
- `--session-id=<uuid>` sets the `session_id` that `init` and `result` report, so the host knows the id before the first line.
- A user line with a `uuid` gives `{"type":"command_lifecycle","command_uuid":"...","state":"queued"|"started"|"completed"}` lines. `--replay-user-messages` echoes each user line with that `uuid` and `"isReplay":true`.
- A string `content` is accepted: `{"type":"user","message":{"role":"user","content":"text"},"parent_tool_use_id":null,"session_id":""}`.
- `init.capabilities` lists features, for example `["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1","mcp_read_resource_v1","mcp_tool_ui_meta_v1"]`. A host can check a feature here instead of a version.
- **End of file on stdin.** When idle, the program exits with status 0 in about 0.5 s. When a turn runs with a message queued, it finishes the queued turns, writes their `result` lines, and then exits with status 0.

### A user line during a turn (verified)

- **During a tool call**, the line joins the running turn after the tool results. This is a steer: one `result` with `num_turns: 2`, and the reply obeyed the new line.
- **During the final text answer**, the line waits and runs as the next turn, with its own `result`.
- **`"priority":"now"`** on the user line (a field of the TypeScript `SDKUserMessage`, values `now`, `next`, `later`; not documented) stopped the running answer at once. The stopped turn gave `"subtype":"success"`, `"terminal_reason":"aborted_streaming"`, and the partial text in `result`. The new line then ran as the next turn.

### Control messages

Host to program (source, verified for the subtypes marked below):

```json
{"type":"control_request","request_id":"req_1_ab12cd34","request":{"subtype":"interrupt"}}
```

Program to host:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"req_1_ab12cd34","response":{}}}
```

An error answer is `{"subtype":"error","request_id":...,"error":"text"}`. The host chooses its own request ids. The program's own requests use UUIDs, and the host answers with the same `request_id` in a `control_response`. A host answers a subtype that it does not support with `subtype: "error"` (source). The program can withdraw a pending request with `{"type":"control_cancel_request","request_id":...}` (source; not observed).

| Subtype, host to program | Status | Notes |
|---|---|---|
| `initialize` | verified | `{"subtype":"initialize","hooks":null}`; optional `agents`, `skills`, and more. The response has `commands`, `agents`, `models` (aliases and full names), `account`, `pid`, `current_permission_mode`, and `session_state` |
| `interrupt` | verified | The response is `{"still_queued":[<uuids>]}`. Queued user lines are kept and run next. The TypeScript SDK adds `cancel_queued: true` to drop them (source) |
| `set_model` | verified | `{"subtype":"set_model","model":"sonnet"}`. The program echoes a `user` line with `<local-command-stdout>Set model to ...`. The next turn ran on the new model and knew the earlier context |
| `mcp_status` | verified | The state and tools of each MCP server |
| `set_permission_mode`, `rewind_files`, `mcp_reconnect`, `mcp_toggle`, `stop_task`, `get_context_usage` | source | Not verified |

Program-to-host subtypes: `can_use_tool` and `mcp_message` (verified), `hook_callback` and `elicitation` (source).

### Interrupt (verified)

- **During streamed text:** the `control_response`, the partial `assistant` line, a `user` line `[Request interrupted by user]`, then `"subtype":"error_during_execution"`, `"is_error":true`, `"terminal_reason":"aborted_streaming"`. The `result` came about 50 ms after the request.
- **During a foreground `Bash` call:** `system/task_notification` with `"status":"stopped"`, an `is_error` tool result, a `user` line `[Request interrupted by user for tool use]`, then `error_during_execution` with `"terminal_reason":"aborted_tools"`. The `sleep` child was gone 1 s later.
- **A background `Bash` task survives an interrupt.**
- In each case the process stayed alive, and the next user line ran with the full context.
- So `is_error` with `terminal_reason` `aborted_*` is an abort, not a failure.

### Permission requests (verified)

- The program asks the host only with `--permission-prompt-tool stdio`. Without the flag, in the default mode, `Write` was denied with no request: a `{"type":"system","subtype":"permission_denied","tool_name":"Write",...}` line and an `is_error` tool result. A read-only command (`echo`) was not asked.
- Request: `{"type":"control_request","request_id":"<uuid>","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch original.txt",...},"permission_suggestions":[...],"blocked_path":"...","tool_use_id":"toolu_..."}}`.
- Allow: `{"behavior":"allow","updatedInput":{...}}`, with optional `updatedPermissions`. A changed input ran as changed. **The `assistant` `tool_use` line keeps the original input**, so a host that changes the input must record the changed input itself.
- Deny: `{"behavior":"deny","message":"..."}` gives an `is_error` tool result with that text and an entry in `result.permission_denials`. An optional `"interrupt": true` also stops the turn (source).
- The program can send the next `can_use_tool` before the result of the earlier tool.

### Host tools through an SDK MCP server (verified)

- `--mcp-config '{"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}}' --strict-mcp-config`.
- The program sends MCP JSON-RPC inside `mcp_message` control requests: `{"subtype":"mcp_message","server_name":"helyx","message":{"jsonrpc":"2.0","id":0,"method":"initialize",...}}`. The host answers `{"subtype":"success","request_id":...,"response":{"mcp_response":{"jsonrpc":"2.0","id":0,"result":{...}}}}`.
- Order: `initialize`, `notifications/initialized`, `tools/list`, then `tools/call` with `{"name":"secret_word","arguments":{...},"_meta":{"claudecode/toolUseId":"toolu_...","progressToken":2}}`.
- The model sees the tool as `mcp__helyx__secret_word`. A reply `{"content":[{"type":"text","text":"..."}]}` became an ordinary tool result.
- MCP tools are deferred: the model called `ToolSearch` before it called the tool. A way to turn the deferral off was not looked for.
- This needs no HTTP server and no extra process.

### Processes (verified)

- The `Bash` tool runs each command as `/bin/zsh -c ...` with the program as its parent and **in a process group of its own** (pgid equal to its pid). A signal to the program's group does not reach it.
- `SIGTERM` to the program: exit status 143 in about 0.7 s. It first killed its background tasks (`task_updated` with `"status":"killed"`), and no child was left.
- `SIGKILL` to the program: the foreground `zsh` and its `sleep` were left running with parent 1.
- The SDKs close the program with end of file on stdin, then `SIGTERM`, then `SIGKILL`. Python waits 5 s before each signal. TypeScript waits 2 s before `SIGTERM` and 5 s before `SIGKILL`. Neither starts the program in a new process group (source).

### Helyx abort with a command in its own group (2026-09-26)

Four aborts through `Helyx.Session.abort/1` with `Helyx.Provider.ClaudeCode` (`2.1.283`, `haiku` and `sonnet`): a foreground `python3 -c "import time; time.sleep(90)"`, and in one run a background task of the same kind. Each abort returned in 537 to 613 ms, and `ps` found no process of the command 2 s later. The watchdog TERMs the program's group and KILLs it after 500 ms. The program ends its commands on the TERM within that time. The margin is small: a program with more children, or a slower machine, can need more than 500 ms, and a KILL then leaves the command groups running. `Helyx.Provider.Codex` already uses a TERM grace of 5 s for the same reason.
