# Coding agent (checkpoint one)

A terminal coding agent built on Helyx. It is the first product and it proves the substrate.

## Goal

From the TUI, prompt the agent about a repository. It reads, edits, and runs shell commands in a loop. Output streams. Abort, steer, and follow-up work during a turn. The session resumes after a restart. One user: the author, on this repository.

## Shape

- Root `helyx` Mix project. Plugins under `plugins/` and the product under `apps/coding_agent` are separate Mix projects that depend on Helyx by path. No umbrella.
- Elixir 1.19 and OTP 28, pinned in `.tool-versions`. Started with a Mix task.

## Runtime

- One session process per conversation, started under a DynamicSupervisor and found by id through Registry.
- Each turn has a turn id and runs in a Task under Core's task supervisor. The session monitors the Task and ignores messages from a Task that is no longer current.
- One hands process per session runs tool calls as Tasks and spawns harness programs. See ADR 0003.
- Core starts as a child spec that takes the plugin list. No application config.
- Interface modes: Provider, Tool, and Event are `multi`. ModelContext, Compaction, and Transport are `single`.

### Abort

Abort ends the current turn by id. The session kills the turn Task and tells the hands to cancel that turn id. The hands kill every tool Task for that turn and stop every operating system process it started for that turn. Closing a port does not stop the command behind it, so the hands start each shell command and each harness program in its own process group, send `SIGTERM` to the group on abort, and send `SIGKILL` after a short grace period. The hands reply to the session only after every process in the group is gone, and the session starts the next turn only after that reply. Every tool result and harness event carries its turn id, and the session drops any that arrive for a turn that is no longer current. A shell command killed mid-write can leave a half-written file. That is accepted.

When a turn is aborted, by the user or by a restart, every tool call in it that has no result gets a tool result entry with `is_error` true and the text `aborted`. The entry is appended to the transcript, so the next provider call sees a complete call and result pair. Providers reject a tool call without a result, so removing the call is not an option.

### Steer and follow-up queues

Queued steers join the transcript as user messages, in order, before the next provider call inside the turn. Queued follow-ups start a new turn after the current turn ends normally; anything still queued at that point, steers included, becomes that one new turn's prompt, steers first, so no typed message is lost. A steer or follow-up sent with no turn running starts a turn at once, like a prompt, so the client never races the end of a turn. Abort and turn failure drop both queues. Every change emits a `queue_update` event; the drain at a normal turn end goes out between turns with a nil turn id, and `Helyx.Session.queue_count/1` reads the counts. Each queue holds at most 32 entries; past the cap the call returns `{:error, :queue_full}` and the TUI keeps the text in the composer, with no visible notice yet, ticket #46.

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

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| file read (read, edit, model context) | one regular file, at most 10,485,760 bytes, valid UTF-8 | a device, a directory, or a larger file is an error; invalid UTF-8 is an error, `binary file, N bytes` |
| tool result text | 2000 lines or 51,200 bytes of line content, on whole lines | read keeps the head and bash keeps the tail; the result says which absolute lines it shows, and a truncated head names the offset that continues the read |
| bash output buffer while the command runs | the last 204,800 bytes | older output is dropped, the result says so; the byte cut can land inside a character, and the fragment becomes U+FFFD at delivery |
| tool result text validity | valid UTF-8 before it enters the transcript | the hands replace each invalid byte sequence with one U+FFFD (`String.replace_invalid/1`) before the session sees the result; replacement runs after a tool's own truncation and can grow the text to at most three times its byte size |
| bash command and working directory | no NUL byte; port arguments and the cd option are NUL-terminated C strings that would cut the string silently | an error result before the port opens; nothing runs |
| bash working directory at port open | must still exist; the hands check it, but it can vanish before the port opens | open, ticket #52: the port reports exit code 2 in an ok result for a command that never ran |
| wait for a bash command | unbounded; abort ends it (the bash tool's `ponytail:` marker) | the turn abort kills the command's process group |
| wait for a killed process group | 500 ms TERM grace, then KILL, then a 5 s ceiling of real elapsed time | a group that survives KILL past the ceiling is stuck: the result is an error, `cancel/2` reports the failure, and the hands refuse later tool calls with an error result while the group lives; chat, abort, and quit are not blocked |

## Ownership

When anything above a command dies, the command stops. Two rules cover every path (ADR 0004): inside the VM, work is linked to its owner, and the owner traps exits so a crash below it stays a message; at the OS boundary, a command's life is tied to its port through the perl watchdog. perl is required; the bash tool's `check/0` reports a system without it when the hands start, and the session fails to start with a clear error.

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| provider stream Task | session | session, linked | reply consumed, monitor flushed | the link kills the Task with the session, even through an untrappable kill | `Task.shutdown(:brutal_kill)` |
| tool Task | hands | hands, linked | result delivered | the link kills the Task with the hands; a Task's own crash becomes an error result | `cancel/2` brutal-kills the turn's Tasks |
| command port | bash tool, inside the tool Task | the Task | closes when the watchdog exits | closes when the Task dies, however it died, down to a `kill -9` of the whole VM | closes when the Task is killed |
| command process group | the watchdog's fork; the id is registered with the hands before the command may run | hands (the id) and watchdog (the life) | the hands KILL the group at delivery and wait until it is gone | the closed port ends the watchdog's stdin: TERM, 500 ms grace, KILL, reap | `cancel/2` TERMs and KILLs the registered groups and returns only when every one is gone |
| watchdog process (its own group) | `Port.open` in the bash tool; registered with the hands like a group | the port | exits after it reaps the command | the closed port is its signal; it ignores TERM so a group sweep cannot cut its cleanup short | the hands wait for it, so an abort cannot return while the command is unreaped |

A call can register several groups; the hands hold them as a set per Task, and every one is cleaned. A group that survives KILL is remembered as stuck (see the bounds table). A child that leaves its process group on purpose with `setsid` stays a documented limit.

## Transcript and events

- Message shape and session file format: see ADR 0001 and the section below.
- Session files live under `~/.helyx/sessions/<project>/<session>.jsonl`.
- Ten events: `agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`, `tool_execution_start`, `tool_execution_end`, `queue_update`. Each carries the session id, the turn id (nil on the queue drain between turns), and a sequence number.

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
- The format owns a closed `stop_reason` set: `end_turn`, `tool_use`, `max_tokens`. A reader decodes them without touching the atom table's history, so a fresh VM resumes a saved file. A terminal event with a stop reason outside the set, or a usage the file cannot encode, fails the turn as a malformed stream event before the message exists. A new stop reason is a format change.
- A tool result links to its call by `tool_call_id`. A tool call with no result after the turn ended gets an `aborted` error result on resume (see Abort).
- Streamed partial messages are not written. Only the completed message is appended, after the provider finishes it.
- A file is read line by line. A last line that does not parse is a torn write. On open, the file is truncated to the end of the last line that parses before anything is appended.
- On resume, the leaf is the last entry in file order.
- A reader never raises at the caller. A header with an unknown or missing version, and an entry with a shape the writer never produces, come back as `{:error, reason}`. Only the last line can be repaired: a bad line mid-file is a malformed file and is rejected without truncation. A repair that cannot write, and a sessions directory that cannot be written on create, are their own error classes.
- Provider deltas that are not valid UTF-8, and tool calls whose fields the file cannot encode, fail the turn as malformed stream events; prompts that are not valid UTF-8 are rejected at the client. Transcript text is valid, and every value in it survives the round trip to the file, from the moment it exists.
- Tool output is scrubbed to valid UTF-8 when it becomes a tool result message, so every consumer of the transcript, the file and the providers, sees valid text. Invalid bytes become replacement characters.
- A write failure mid-session logs a warning, turns persistence off for that session, and the turn continues on the in-memory transcript.

Bounds:

| What | Bound | Over the bound |
|---|---|---|
| Session file on resume | Unbounded, one conversation per file, read whole into memory | Accepted for checkpoint one; compaction bounds the transcript itself (#1) |
| Project directory slug | Last 100 characters of the slugged cwd | Collisions are disambiguated by the header `cwd` |
| Prompt text | Must be valid UTF-8 | `{:error, :invalid_utf8}` at the client boundary |
| Steer and follow-up queues | 32 entries each; entry text is human input, size accepted as unbounded (#29) | The session returns `{:error, :queue_full}` |
| `cwd` and model on create | Must be valid UTF-8 | `{:error, {:create_failed, :invalid_utf8}}` |
| SSE line from the model gateway | 1 MiB, terminated or not; the buffer overshoots by at most one transport chunk | One `{:error, {:line_over_limit, limit}}` event ends the stream |
| Tool call bytes per response (argument fragments with a flat charge each, ids, names, entry keys, a flat charge per call) | 10 MiB across all calls, overshooting by at most one line; integer call indexes at most 10,000 | One `{:error, {:tool_call_bytes_over_limit, limit}}` event ends the stream; no partial call is emitted |
| HTTP error response body | 16 KiB; the accumulator overshoots by at most one transport chunk | The body is cut to valid UTF-8 at the limit and marked `[truncated at the N-byte limit]`; the rest of the response is cancelled |

The three provider limits carry no research citation: `docs/research/coding-tools.md` covers tool output truncation, not gateway input, so the values are set here.

Ownership:

| Resource | Holder | Release |
|---|---|---|
| Session file handle | The calling process; every read and append opens and closes inside one `SessionFile` call | On return; no handle outlives a call |

A `Session.start` that fails after the file is created (a supervisor or hands failure) can leave a header-only session that a later resume restores as an empty transcript with the right model. Open, accepted for checkpoint one; the window is narrowed by creating the file only after the plugins resolve.

Two more holes are open and accepted for checkpoint one. Nothing locks a session file: two runtimes that resume the same file both append from the same leaf and interleave their entries. Local mode is one user in one node; a lock lands with a multi-node transport. And a resumed session starts a new event stream: sequence numbers restart at one, and a client renders from the restored transcript, not from event history.

## TUI

- ex_ratatui, alternate screen. The TUI is `Helyx.TUI` under `plugins/tui`. It implements no Core interface and is not in Core's plugin list: it is a client that subscribes to one session. Local delivery is OTP messages from `Helyx.Session.subscribe/1`; a Transport interface arrives with the first remote client.
- The view model is a pure fold over events, `Helyx.TUI.ViewModel`, tested with scripted event lists. It grows with the conversation, bounded by the session. The composer is human input; its size is accepted as unbounded, like a queue entry's text (#29). Tool results render at most four content lines each, plus one truncation row naming the hidden line count.
- Escape aborts. Enter sends a steer during a turn and a prompt when idle. Alt plus Enter queues a follow-up: most terminals cannot tell Shift+Enter from Enter without the kitty keyboard protocol, so Alt is the modifier. The status bar shows the model, the run state, and the queue counts.
- Queued steers are delivered together at the next provider call. On a harness turn, a steer aborts and resends (see Harness turns).
- The `helyx` Mix task lives in `apps/coding_agent`. `mix helyx [directory] [--model provider/model] [--resume]` starts Core with the bundled plugins, one session in `directory` (default: the current one), and the TUI, and quitting restores the terminal. The session is written under `~/.helyx/sessions`; `--resume` continues the most recent session for the directory with its saved model, so it does not combine with `--model`.

## Out of scope

MCP, sub-agents, permission prompts, plan mode, todos, background shell, compaction, branching, editing queued messages, queue persistence, remote hands, packaging, Anthropic API key provider, dedicated grep, find, and ls tools, skills discovery, replaying the transcript into a fresh harness session. During a harness turn, Helyx tools are not visible to the model (ADR 0002).
