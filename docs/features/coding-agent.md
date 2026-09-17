# Coding agent (checkpoint one)

A terminal coding agent built on Helyx. It is the first product and it proves the substrate.

## Goal

From the TUI, prompt the agent about a repository. It reads, edits, and runs shell commands in a loop. Output streams. Abort, steer, and follow-up work during a turn. The session resumes after a restart. One user: the author, on this repository.

## Shape

- Root `helyx` Mix project. Plugins under `plugins/` and the product under `apps/coding_agent` are separate Mix projects that depend on Helyx by path. No umbrella.
- Elixir 1.19 and OTP 28, pinned in `.tool-versions`. Started with a Mix task.

## Runtime

- One session process per conversation, started under a DynamicSupervisor and found by id through Registry.
- Each turn has a turn id and runs in a Task under the session.
- One hands process per session runs tool calls as Tasks and spawns harness programs. See ADR 0003.
- Core starts as a child spec that takes the plugin list. No application config.
- Interface modes: Provider, Tool, and Event are `multi`. ModelContext, Compaction, and Transport are `single`.

### Abort

Abort ends the current turn by id. The session kills the turn Task and tells the hands to cancel that turn id. The hands kill every tool Task for that turn and stop every operating system process it started for that turn. Closing a port does not stop the command behind it, so the hands start each shell command and each harness program in its own process group, send `SIGTERM` to the group on abort, and send `SIGKILL` after a short grace period. The hands reply to the session only after every process in the group is gone, and the session starts the next turn only after that reply. Every tool result and harness event carries its turn id, and the session drops any that arrive for a turn that is no longer current. A shell command killed mid-write can leave a half-written file. That is accepted.

When a turn is aborted, by the user or by a restart, every tool call in it that has no result gets a tool result entry with `is_error` true and the text `aborted`. The entry is appended to the transcript, so the next provider call sees a complete call and result pair. Providers reject a tool call without a result, so removing the call is not an option.

## Interfaces and bundled plugins

| Interface | Plugins in this checkpoint |
|---|---|
| Provider | `OpenAI` (model provider, OpenAI wire format, first target OpenCode Go or Zen), `ClaudeCode` (harness, `claude -p` stream-json over stdio), `Codex` (harness, `codex app-server` JSON-RPC over stdio), `Fake` (scripted, for tests) |
| Tool | `Read`, `Bash`, `Edit`, `Write` |
| ModelContext | `Default`: base prompt plus `AGENTS.md` files from home down to the working directory |
| Compaction | `None`: no-op |
| Event | the TUI subscribes; no bundled handlers |
| Transport | `Local`: OTP messages in one node |

A model is named by one string, `provider/model`. Core parses it once.

### Harness turns

A harness runs its own loop and its own tools. Helyx starts the program for the turn, translates its output into messages and events, and records them in the transcript. Helyx tools are not visible to the harness (ADR 0002).

- Steer: a harness does not accept a message inside a turn. On a harness turn, a steer aborts the turn and starts a new turn with the steer as its prompt. The transcript keeps whatever the harness completed before the abort.
- Resume: each harness issues its own session id. Helyx writes it to the transcript as a `harness_session` entry when the first harness turn starts, and passes it back on later turns and after a restart. If the harness no longer has that session, the next harness turn starts a fresh harness session, the transcript gets a new `harness_session` entry, and the TUI shows a notice that the harness lost its own context. The Helyx transcript is unaffected. Replaying the transcript into a fresh harness session is out of scope.

## Transcript and events

- Message shape and session file format: see ADR 0001 and the section below.
- Session files live under `~/.helyx/sessions/<project>/<session>.jsonl`.
- Ten events: `agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`, `tool_execution_start`, `tool_execution_update`, `tool_execution_end`. Each carries the session id, the turn id, and a sequence number.

### Session file

One JSON object per line. Every entry has `id`, `parent_id`, `ts`, and `type`. The first entry is the header and its `parent_id` is null. Example entries, one per kind:

```json
{"id":"01J...","parent_id":null,"ts":"2026-09-17T10:00:00Z","type":"session","version":1,"cwd":"/path/to/repo","model":"opencode-go/kimi-k2"}
{"id":"01J...","parent_id":"01J...","ts":"...","type":"message","role":"user","content":[{"type":"text","text":"List the tests."}]}
{"id":"01J...","parent_id":"01J...","ts":"...","type":"message","role":"assistant","model":"opencode-go/kimi-k2","stop_reason":"tool_use","usage":{"input":120,"output":40},"content":[{"type":"text","text":"Listing."},{"type":"tool_call","id":"call_1","name":"bash","arguments":{"command":"ls test"}}]}
{"id":"01J...","parent_id":"01J...","ts":"...","type":"message","role":"tool_result","tool_call_id":"call_1","tool_name":"bash","is_error":false,"content":[{"type":"text","text":"core_test.exs"}]}
{"id":"01J...","parent_id":"01J...","ts":"...","type":"model_change","model":"claude-code/opus"}
{"id":"01J...","parent_id":"01J...","ts":"...","type":"harness_session","provider":"claude-code","harness_session_id":"..."}
```

Content blocks: `text` has `text`. `thinking` has `thinking` and an optional `signature`. `tool_call` has `id`, `name`, and `arguments`. `image` has `mime_type` and base64 `data`.

Rules:

- The header carries `version`. A reader rejects a version it does not know.
- A tool result links to its call by `tool_call_id`. A tool call with no result after the turn ended gets an `aborted` error result on resume (see Abort).
- Streamed partial messages are not written. Only the completed message is appended, after the provider finishes it.
- A file is read line by line. A last line that does not parse is a torn write. On open, the file is truncated to the end of the last line that parses before anything is appended.
- On resume, the leaf is the last entry in file order.

## TUI

- ex_ratatui, alternate screen.
- Escape aborts. Enter sends a steer during a turn. A modifier plus Enter queues a follow-up. The status bar shows the queue count.
- Queued steers are delivered together at the next provider call. On a harness turn, a steer aborts and resends (see Harness turns).

## Out of scope

MCP, sub-agents, permission prompts, plan mode, todos, background shell, compaction, branching, editing queued messages, queue persistence, remote hands, packaging, Anthropic API key provider, dedicated grep, find, and ls tools, skills discovery, replaying the transcript into a fresh harness session. During a harness turn, Helyx tools are not visible to the model (ADR 0002).
