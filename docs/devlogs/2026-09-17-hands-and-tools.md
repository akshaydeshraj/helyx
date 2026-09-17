# Hands and the four tools (ticket #3)

## Done

- `Helyx.Tool` interface: `name/0`, `description/0`, `parameters/0` (JSON schema map), `run/2` with the argument map and the working directory. Result is `{:ok, text}` or `{:error, text}`. `Helyx.Tool.truncate/2` caps text at 2000 lines or 50 KB on whole lines; `:head` for read, `:tail` for bash.
- `Helyx.Hands`: one GenServer per session, linked from the session's `init`. It reads the Tool plugins from Core, reports their specs, and runs each call in a Task under Core's task supervisor. The Task sends `{:tool_result, turn_id, call_id, result}` to the session. A tool that raises, throws, or returns the wrong shape is an error result. An unknown tool name is an error result.
- Session loop: after an assistant message with tool calls, every call goes to the hands with a `tool_execution_start`. Results arrive in any order with `tool_execution_end`. When all are in, the tool result messages join the transcript in call order and the provider is called again. The turn ends on an assistant message with no tool calls. Messages for a turn that is not current are dropped.
- `Helyx.Context` carries `tools`. `Session.start/2` takes `cwd:` (default `File.cwd!/0`).
- Fake provider scripts tool calls: a response item can be a `ToolCall`; such a response stops with `:tool_use`. `Fake.run_tool/3` runs one call through a session for plugin tests.
- Four plugins: `plugins/tool_read`, `tool_bash`, `tool_edit`, `tool_write`. Bash launches through perl `setpgrp` so the port's OS pid is the group leader; stdin is `/dev/null`; a non-zero exit is an `Exit code: N` line in the text, not an error result. Edit is exact match, exactly once. Write creates directories.

## What broke

- The `blocks` test model called `bash` on every provider call, which the new loop turned into an infinite turn. The model now answers with text after a tool result.
- The ordering of `tool_execution_end` is arrival order, not call order. The test asserted call order and was wrong; the transcript order is what is fixed.
- A trailing newline counted as a line in `truncate/2`, so `seq 1 3000` reported 3001 lines.

## Decisions taken without a ticket line

Defaults from the tools research, agreed in chat: 2000 lines or 50 KB; exit code in the text; exact-only edit matching; no line numbers in read; no bash timeout in this ticket.

Taken during implementation: read takes an `offset` so the model can continue past the cap; write creates parent directories; bash returns `(no output)` for an empty result and reads stdin from `/dev/null`; a first line over 50 KB is cut to the limit; the hands refuse every tool call when the working directory is gone.

## Review

See `docs/reviews/2026-09-17-issue-3.md`. Three hangs were found and fixed before commit: a dead tool Task, duplicate tool call ids, and a tool call with a non-string name.

## Next

#7 and #8 on the frontier. Abort (later ticket) needs the hands to track the Tasks and OS pids it started; today it tracks nothing.
