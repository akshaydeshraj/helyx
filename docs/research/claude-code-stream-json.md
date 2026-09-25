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
- `--session-id <uuid>` lets the caller choose the id; not verified.
- `--permission-mode` choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`. The `init` line reported `default` with no flag. In `-p` mode nobody can answer a permission prompt. The `Read` tool ran without a prompt. What happens to `Bash`, `Edit`, and `Write` in the default mode was not verified; the `result` line has a `permission_denials` list for it.
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
