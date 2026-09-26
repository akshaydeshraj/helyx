# Research: how coding agents expose a client contract

Date: 2026-09-26. Author: research agent for Helyx.

Question: how does a client (TUI, SwiftUI app) join a session, get state, receive live events with no gap, send operations, list commands, and show rich blocks? What can Helyx copy?

## Sources and revisions

| Source | Revision seen |
|---|---|
| opencode, `github.com/anomalyco/opencode` (shallow clone) | commit `b65de4d6943e`, 2026-09-26 |
| ACP, `github.com/agentclientprotocol/agent-client-protocol` (shallow clone). `zed-industries/agent-client-protocol` now redirects here (`gh api repos/zed-industries/agent-client-protocol` returns `agentclientprotocol/agent-client-protocol`, created 2025-06-23) | commit `b44babba0bbc`, 2026-09-26; releases `schema-v1.23.0` and `schema-v2.0.0-alpha.5`, both 2026-09-18 |
| pi, `github.com/badlogic/pi-mono` (now redirects to `earendil-works/pi`) | commit `2b0a123de983`, 2026-09-26; packages at version 0.87.1 |
| Claude Code docs `https://code.claude.com/docs/en/headless` and `.../cli-reference` | fetched 2026-09-26 |
| Claude Agent SDK, npm `@anthropic-ai/claude-agent-sdk` | 0.3.283, `sdk.d.ts` read 2026-09-26 |
| DeepWiki `anomalyco/opencode` | asked 2026-09-26 (search id `8a2fa6ba-...`) |

Paths below for opencode are relative to `packages/` in the opencode repo. Paths for ACP are relative to the ACP repo root. Paths for pi are relative to `packages/` in the pi repo.

---

## 1. opencode

opencode has two HTTP APIs in the same repo now:

- **v1 (legacy) "instance" API**: `opencode/src/server/routes/instance/httpapi/groups/*.ts`. The TUI uses it.
- **v2 ("experimental") API** under `/api/...`: `protocol/src/groups/*.ts` (contract) and `server/src/handlers/*.ts` (handlers). The web/desktop app (`app/`) and the new in-process SDK (`sdk-next/`) use it. The OpenAPI annotation calls these routes "Experimental" (`protocol/src/groups/session.ts`, last lines).

### (a) `/compact` and `/undo`: client actions that call typed routes

Verified in source. They are **not** sent through `POST /session/:id/command`.

- TUI `/compact` (alias `/summarize`) calls `sdk.client.session.summarize(...)` (`tui/src/routes/session/index.tsx` lines 561-585). This is `POST /session/:sessionID/summarize` (`opencode/src/server/routes/instance/httpapi/groups/session.ts` line 94, endpoint at line 303).
- TUI `/undo` first calls `session.abort` if the session is busy, then `session.revert({messageID})`, then puts the old prompt text back in the input box (`tui/src/routes/session/index.tsx` lines 610-640). This is `POST /session/:sessionID/revert` (line 99 in the group file). `/redo` calls `unrevert` or `revert` again.
- The web/desktop app uses v2 routes: `sdk().api.session.compact(...)` and `session.revert.stage` / `session.revert.clear` (`app/src/pages/session/use-session-commands.tsx` lines 356, 382, 392, 398-414). The v2 routes are `POST /api/session/:id/compact`, `/revert/stage`, `/revert/clear`, `/revert/commit` (`protocol/src/groups/session.ts` lines 226-290).
- `POST /session/:id/command` exists (v1 group line 343), but it runs a **server command**, which is a prompt template (see (e)).
- The TUI decides locally: if the typed first word matches a server command name from `command.list`, it calls `session.command`. Otherwise the slash entry is a TUI action with a `run()` function (`tui/src/component/prompt/index.tsx` lines 1071-1091).

DeepWiki disagreement: DeepWiki says the **TUI** `/compact` calls `POST /api/session/:id/compact` and `/undo` calls `revert/stage`. At `b65de4d` that is true only for the web app (`app/`). The TUI calls the v1 `summarize` and `revert` routes.

### (b) Desktop app: starts its own server, and can also connect to others

Verified in source. DeepWiki is wrong here: it says the desktop app "does not start its own server".

- The Electron main process picks a free port on `127.0.0.1`, makes a random password, and calls `spawnLocalServer` (`desktop/src/main/index.ts` lines 360-390).
- `spawnLocalServer` forks `sidecar.js` in an Electron `utilityProcess` (`desktop/src/main/server.ts` lines 57-70). The sidecar imports the server and calls `Server.listen({port, hostname, username: "opencode", password, cors: ["oc://renderer"]})` (`desktop/src/main/sidecar.ts` lines 51-66).
- The renderer can also select a stored "default server" URL (`desktop/src/main/server.ts` lines 30-43; `desktop/src/renderer/index.tsx` lines 275-283) and WSL servers on Windows. So the app is a thin HTTP client. It starts a local server by default.

### (c) Event stream, replay after `after`, and first state

There are three event streams. Only one supports replay.

1. **v1 `GET /event`** (SSE, the TUI uses it). No replay and no sequence. The handler registers a listener first ("Listener registration is eager, so events published after this point cannot be lost"), sends `server.connected`, then live events, plus `server.heartbeat` each 10 s. Event ids are random (`EventV2.ID.create()`) (`opencode/src/server/routes/instance/httpapi/handlers/event.ts`).
   - First state: the TUI subscribes to events first (`tui/src/context/sync.tsx` line 176), then runs `bootstrap()` on mount (line 555). `bootstrap()` fetches project, sessions, providers, agents, config, commands (lines 451-530). On `server.instance.disposed` it runs `bootstrap()` again (line 178). Per session it fetches messages with `sync(sessionID)` (line 594). Events are patches on a local store: `message.updated`, `message.part.updated`, `message.part.delta` (append `delta` to a `field` of a part), `message.part.removed`, `session.status`, `permission.asked`, and more (lines 176-450).
   - Weakness: after a reconnect, the client cannot know what it missed. It must refetch.
2. **v2 `GET /api/event`**: server-wide SSE of all events. Events can carry `durable: {aggregateID, seq, version}`. No `after` parameter (`protocol/src/groups/event.ts`).
3. **v2 `GET /api/session/:sessionID/event?after=<seq>`**: "Replay durable events after an aggregate sequence, then continue with new durable events" (`protocol/src/groups/session.ts` lines 327-343). Also `GET /api/session/:id/history?after=&limit=` (max 100) for finite pages (lines 307-325).
   - Implementation (`core/src/event.ts` lines 565-603): the stream first subscribes a "wake" PubSub for the aggregate (sliding, size 1). Then it reads all rows after `seq` from the database and remembers the last `seq`. Each wake makes it read again from the database after the last `seq`. Because the subscription exists before the first read, no commit can fall between them. This is gap-free by construction, and the database is the source of truth, not the PubSub.
   - First state in v2: `GET /api/session/:id` (info), `GET /api/session/:id/message` (projected messages, cursor pages, limit 1-200) (`protocol/src/groups/message.ts`), `GET /api/session/:id/context` (messages after the last compaction). I did not find a single call that returns "snapshot plus the seq it is valid at". A client can instead replay from `after` = its last seen seq, or from the start.

### (d) The "internal" transport for in-process use

Verified in source. It is the same HTTP router with no socket.

- `opencode run` builds an SDK client with `baseUrl: "http://opencode.internal"` and a custom `fetch` that calls `Server.Default().app.fetch(request)` in the same process (`opencode/src/cli/cmd/run.ts` lines 909-960).
- The TUI runs the server in a Bun `Worker`. The TUI thread gets a `fetch` that sends each request over worker RPC (`client.call("fetch", ...)`), and an event source fed by `Rpc.emit("global.event", event)` from the worker (`opencode/src/cli/cmd/tui.ts` lines 24-56, 210-290; `opencode/src/cli/tui/worker.ts` lines 23-80). With a network flag, it uses a real URL instead.
- `sdk-next` (new, "transitional"): "executes Server's assembled HTTP router in memory. It opens no listener and performs no network I/O, while preserving the same routing, middleware, handlers, codecs, and errors as the network client" (`sdk-next/README.md`). It exposes `sessions.events({sessionID, after})` with the same replay rule.

### (e) Commands: how they are listed and what they can do

- v1: `GET /command`; the TUI stores the list (`tui/src/context/sync.tsx` line 523). v2: `GET /api/command` returns `Command.Info[]` (`protocol/src/groups/command.ts`).
- `Command.Info` = `{name, template, description?, agent?, model?, subtask?}` (`schema/src/command.ts`).
- Sources: built-in `init` and `review`, config `command` entries, MCP prompts, and skills (`opencode/src/command/index.ts` lines 68-140; `source: "command" | "mcp" | "skill"`).
- A server command can only do one thing: expand a prompt template with arguments and send it to the model, optionally with a given agent or model, optionally as a subtask. It cannot run arbitrary server code.
- Client actions such as `/compact`, `/undo`, `/share`, `/new`, `/themes` are defined in each client. The TUI and the web app each have their own list.

### (f) Message parts and rendering

- v1 `Part` union (`schema/src/v1/session.ts` lines 357-370): `text`, `subtask`, `reasoning`, `file`, `tool`, `step-start`, `step-finish`, `snapshot`, `patch`, `agent`, `retry`, `compaction`. Each part has an `id` and a `messageID`. Tool state is a union `pending | running | completed | error`.
- v2 `Session.Message` union (`schema/src/session-message.ts` lines 214-226): `agent-switched`, `model-switched`, `user`, `synthetic`, `system`, `shell`, `assistant`, `compaction`. An `assistant` message has `content: (text | reasoning | tool)[]`, plus `snapshot`, `cost`, `tokens`, `error`. A `tool` item has `state` tagged by `status` (`pending` with raw `input` string, `running`, `completed`, `error`), each with `content: ToolContent[]` (text or file, `schema/src/llm.ts` line 25) and a free `structured` record.
- Rendering: clients switch on `type` and on tool `name`. The TUI has per-tool renderers. The `structured` field carries tool-specific data (for example, a diff) that the tool's renderer knows. I did not audit each renderer.

### What Helyx should copy or avoid (opencode)

- Copy: the v2 durable session stream: per-session sequence number, `after=seq` replay then live, and "subscribe before read" to close the gap.
- Copy: typed operations for `compact`, `revert`, `interrupt`, and `prompt`; commands only as prompt templates.
- Copy: one contract for in-process and network use (same router, different transport).
- Copy: v2 `prompt` returns "admitted" and the loop runs on its own (`session.prompt` "Durably admit one session input and schedule agent-loop execution", `protocol/src/groups/session.ts` lines 205-224).
- Avoid: the v1 split. Two APIs, and a TUI-only `/tui/*` route group (`opencode/src/server/routes/instance/httpapi/groups/tui.ts`) that lets the server drive the TUI.
- Avoid: an event stream with no sequence, which forces a full refetch on reconnect.

---

## 2. Agent Client Protocol (ACP)

### Status, versions, dates

- ACP v1 is stable. Schema `v1.23.0`, 2026-09-18 (`schema/v1/CHANGELOG.md`). Rust and TypeScript SDKs reached 1.0 on 2026-06-25 (`docs/updates.mdx`).
- ACP v2 is a **Draft**, announced 2026-07-20 (`docs/announcements/acp-v2-draft.mdx`). Latest schema `v2.0.0-alpha.5`, 2026-09-18 (GitHub releases). The announcement says: "various pieces can, and will, change before stabilization" and "gate your implementation behind the version negotiation AND feature flags".
- Governance moved from Zed to an `agentclientprotocol` org; the repo redirects.

### Transport

- JSON-RPC 2.0, UTF-8. Primary transport: **stdio**. "The client launches the agent as a subprocess." Newline-delimited messages, no embedded newlines, logs on stderr (`docs/protocol/v1/transports.mdx`). v2 adds JSON-RPC batches (`docs/protocol/v2/transports.mdx`).
- Remote transport (Streamable HTTP plus WebSocket on one `/acp` endpoint) is an RFD in **Draft** since 2026-04-22 (`docs/rfds/updates.mdx`). It says "In-flight messages are not replayed. There is no message sequencing or stream resumption" and it defers `Last-Event-ID` resumption to v2 (`docs/rfds/streamable-http-websocket-transport.mdx` lines 74-84, 353, 365).

### Methods (v1)

From `schema/v1/meta.json`:

- Client to agent: `initialize`, `authenticate`, `session/new`, `session/load`, `session/resume`, `session/list`, `session/close`, `session/delete`, `session/prompt`, `session/cancel` (notification), `session/set_mode`, `session/set_config_option`, `logout`.
- Agent to client: `session/update` (notification), `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`, `terminal/create|output|release|wait_for_exit|kill`, `elicitation/create`, `elicitation/complete`.
- Both: `$/cancel_request`.

v2 changes (`docs/protocol/v2/migration.mdx` "At a glance"): `session/load` removed; `session/resume` gains `replayFrom`. `set_mode` removed (modes become config options). `fs/*` and `terminal/*` removed. `authenticate` becomes `auth/login`.

### Join and replay

- v1 `session/load` (capability `loadSession`): the agent "MUST replay the entire conversation to the Client in the form of `session/update` notifications", then answers the request (`docs/protocol/v1/session-setup.mdx`). v1 `session/resume` reattaches with no replay.
- v2 `session/resume` with `"replayFrom": {"type": "start"}` replays everything; no `replayFrom` means no replay. "The cursor is a tagged union so future versions can add replay-from-a-point variants" (migration.mdx lines 572-596). So there is **no replay from a sequence** in v1 or v2 today.
- Multi-client: v2 says the new lifecycle "works for history replay on `session/resume`, multiple clients observing one session" (migration.mdx "Why this matters"). But stdio is one client per process, and the remote transport is a draft.

### Session updates (the event stream)

Extracted from `schema/v1/schema.json` and `schema/v2/schema.json` (`SessionUpdate` union):

- v1: `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`, `available_commands_update`, `current_mode_update`, `config_option_update`, `session_info_update`, `usage_update`.
- v2: `user_message_chunk`, `user_message`, `agent_message_chunk`, `agent_message`, `agent_thought_chunk`, `agent_thought`, `state_update`, `tool_call_content_chunk`, `tool_call_update`, `terminal_update`, `terminal_output_chunk`, `plan_update`, `available_commands_update`, `config_option_update`, `session_info_update`, `usage_update`.
- Preview RFDs (not in the schema yet): `compaction_update` and `compaction_summary_chunk` (Session Compaction RFD, Preview 2026-09-23); session notices (Preview 2026-09-24) (`docs/rfds/updates.mdx`; `docs/rfds/session-compaction.mdx`).

v2 semantics (migration.mdx lines 226-386), which matter most for Helyx:

- `session/prompt` response only acknowledges insertion and returns the user `messageId`. Progress and the end of work come as `state_update` with `running`, `idle` (with `stopReason`), or `requires_action`.
- Messages and tool calls are **upserts keyed by ID**. Omitted field = unchanged, `null` = clear, value = replace, chunk = append. Message IDs are required and agent-owned.
- There is no separate `tool_call` create. The first `tool_call_update` for an ID creates it. `tool_call_content_chunk` appends one content item.

### Content blocks, tool calls, diffs, permissions

- `ContentBlock`: `text`, `image`, `audio`, `resource_link`, `resource` (v1 and v2 schema).
- `ToolCallContent`: `content` (wraps a content block), `diff`, `terminal`. `ToolKind`: `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`. `ToolCallStatus`: `pending`, `in_progress`, `completed`, `failed` (v2 adds `cancelled`). Tool call fields: `toolCallId`, `title`, `kind`, `status`, `content`, `locations`, `rawInput`, `rawOutput`, optional `name` (stable since 2026-09-17).
- Diff v1: `{path, oldText, newText}`. Diff v2: `{changes: [{operation: add|delete|modify|move|copy, path, oldPath?, fileType?, mimeType?}], patch?: {format: "git_patch", text}}` (migration.mdx lines 436-476).
- Permission: `session/request_permission` is a request from agent to client. Options have `optionId`, `name`, `kind` in `allow_once | allow_always | reject_once | reject_always`. v2 adds a required `title`, optional `description`, and a `subject` union (`tool_call` or `command`) (migration.mdx lines 478-530).

### Slash commands

- The agent pushes `available_commands_update` with `[{name, description, input?: {hint}}]` at any time; it replaces the list (`docs/protocol/v1/slash-commands.mdx`). v2 adds `input.type: "text"` (migration.mdx lines 672-697).
- To run a command, the client sends the text `/name args` inside a normal `session/prompt`. The agent parses it. There is no separate command call.

### Who implements it

- Agents listed in `docs/get-started/agents.mdx`: Claude Agent (via Zed's `claude-agent-acp` adapter), Codex CLI (via adapter), Cursor, Gemini CLI, GitHub Copilot (preview), Goose, JetBrains Junie, Kimi CLI, Kiro CLI, Mistral Vibe, OpenCode, OpenHands, Pi (via the `pi-acp` adapter), Qwen Code, Cline, Augment, Factory Droid, and others.
- Clients in `docs/get-started/clients.mdx`: Zed, JetBrains, neovim, Obsidian, Sublime Text, Qt Creator, Toad, acpx, and many desktop apps.
- opencode's ACP agent uses `@agentclientprotocol/sdk` 0.21.0 (`opencode/package.json` line 57), supports `loadSession`, and maps its commands to `available_commands_update` (`opencode/src/acp/service.ts` lines 115, 211, 999).
- Libraries: official Rust, TypeScript, Python, Kotlin, Java. Community: Elixir (`raxol_agent_client_protocol`), Swift (`swift-acp`, `aptove/swift-sdk`, `acp-swift-sdk`) (`docs/libraries/community.mdx`).

### What Helyx should copy or avoid (ACP)

- Copy the v2 session-update semantics: ID-keyed upserts, append chunks, `state_update` with `running | idle | requires_action`, permission requests with `title` and `subject`, structured diffs with `changes` plus `git_patch`, open enums with `_` extensions.
- Copy the tool-call vocabulary (`kind`, `status`, `locations`, content items). It is small and widely known.
- Avoid ACP as Helyx's **own** client wire for now: the client owns the agent process (stdio), the remote transport is a draft with no resumption, replay is "all or nothing", and v2 is not stable.
- Avoid v1 `fs/*` and `terminal/*` (the agent asks the client to touch files). v2 removed them. They conflict with "server owns state".

---

## 3. pi (pi.dev)

### RPC mode

- `pi --mode rpc` runs pi as a long-lived child process. JSONL on stdin/stdout, strict LF framing (`coding-agent/docs/rpc.md`).
- Four record kinds: command (stdin), `response` (stdout, correlated by optional `id`), session event (stdout), extension UI record (both ways) (`rpc.md` "Protocol records").
- `prompt` response carries `disposition`: `started`, `queued`, or `handled`. "It does not mean model work completed." Wait for `agent_settled` (`rpc.md` "Run lifecycle"; `coding-agent/docs/rpc-commands.md` lines 7-45).
- While the agent streams, a prompt must set `streamingBehavior`: `steer` (deliver before the next LLM call) or `followUp` (deliver after the agent stops).
- Command set (`rpc-commands.md` headings): `prompt`, `steer`, `follow_up`, `abort`, `clear_queue`, `new_session`, `get_state`, `get_messages`, `set_model`, `cycle_model`, `get_available_models`, thinking level, queue modes, `compact` (returns the summary and token counts), `set_auto_compaction`, retry control, `bash`, `abort_bash`, `get_session_stats`, `export_html`, `switch_session`, `fork`, `clone`, `get_fork_messages`, `get_entries`, `get_tree`, `get_last_assistant_text`, `set_session_name`, `get_commands`.
- `get_commands` returns extension commands, prompt templates, and skills with `name`, `description`, `source`, `sourceInfo`. Run one by sending `/name` in `prompt`. "Built-in TUI commands (`/settings`, `/hotkeys`, etc.) are not included" (`rpc-commands.md` lines 786-834).

### Events and content

- Events (`coding-agent/docs/json.md`): `agent_start`, `agent_end`, `agent_settled`, `turn_start`, `turn_end`, `message_start`, `message_update` (with `text_delta`, `thinking_delta`, `toolcall_delta` and `*_start`/`*_end`, each with a `contentIndex`), `message_end` ("the authoritative final message"), `tool_execution_start|update|end`, `queue_update`, `entry_appended`, `session_info_changed`, `thinking_level_changed`, compaction and retry events.
- Content blocks (`coding-agent/docs/message-types.md`): `text`, `image`, `thinking`, `toolCall`. Coding-agent messages add `BashExecutionMessage`, `CustomMessage`, `BranchSummaryMessage`, `CompactionSummaryMessage`.

### Join and replay

- RPC mode has no replay or sequence. A client calls `get_state` and `get_messages` for a snapshot. The doc says "Subscribe before sending a prompt to avoid missing a fast completion" (`rpc.md`). One client per process.
- New and **experimental**: `@earendil-works/pi-server`, `pi-protocol` (version 8), `pi-client`, `pi-durable` (`server/README.md`, `protocol/README.md`, `client/README.md`, `durable/README.md`). A session may have many "presentation attachments". Each request carries `{serverId, sessionId, attachmentId}`, so stale frames after a reattach are rejected. Wire frames are length-prefixed CBOR. A service subscription "returns a complete provider snapshot; the binding installs it and then calls `start()` to release updates buffered during hydration" (`client/README.md`). The client "never reconnects or replays requests automatically".

### What Helyx should copy or avoid (pi)

- Copy: `prompt` answers with a disposition (`started | queued | handled`) and a separate "settled" signal. Copy steer and follow-up as explicit prompt modes.
- Copy: the command list includes only what the server can run; client-only commands stay in the client.
- Copy (from the experimental server): "snapshot, then buffered updates" on attach, and an attachment ID that fences stale frames.
- Avoid: a long flat list of RPC verbs that mixes TUI conveniences (`cycle_model`, `export_html`) with core operations.

---

## 4. Claude Code (stream-json and the Agent SDK), in short

- Transport: the SDK spawns the CLI and talks newline-delimited JSON on stdio. `--input-format stream-json` and `--output-format stream-json` (`https://code.claude.com/docs/en/cli-reference`). `--include-partial-messages` adds `stream_event` records with raw API stream deltas (`https://code.claude.com/docs/en/headless`, "Stream responses").
- Messages: `SDKMessage` is a union of 39 types in SDK 0.3.283 (`sdk.d.ts` line 5273). The core ones are `system/init`, `assistant` and `user` (Anthropic Messages API content blocks: `text`, `thinking`, `tool_use`, `tool_result`, `image`, ...), `stream_event`, and `result` (last line, cost and session id). Subagent messages carry `parent_tool_use_id`.
- Control channel: `control_request` / `control_response` / `control_cancel_request` records (`sdk.d.ts` lines 3877, 4925, 4976). Subtypes include `initialize`, `interrupt`, `can_use_tool` (permission callback to the host), `set_model`, `set_permission_mode`, `rewind_files`, `get_context_usage`, `mcp_*`, `reload_skills` (grep of `subtype:` in `sdk.d.ts`).
- State: `system/session_state_changed` with `state: 'idle' | 'running' | 'requires_action'` (`sdk.d.ts` lines 5783-5790). This is the same three states as ACP v2 `state_update`.
- Commands: `supportedCommands()` returns `SlashCommand {name, description, argumentHint, aliases?, builtin?}`. `system/commands_changed` pushes the full list; "Clients should REPLACE their cached command list" (`sdk.d.ts` lines 3718-3727, 9220-9241). Commands run as text in the prompt: "Include `/skill-name` in the prompt string and Claude Code expands it" (headless doc).
- Join and replay: `--resume <id>` or `--continue` restore the conversation for the model. A reader uses `listSessions()`, `getSessionInfo()`, `getSessionMessages()` to read the transcript file (`sdk.d.ts` lines 869, 899, 1094). There is no sequence-based live replay. One process per session.
- Not verified: `--replay-user-messages` (the fetched CLI table was cut off; `SDKUserMessageReplay` exists in `sdk.d.ts` line 6237, but I did not confirm the flag). "Remote Control" (`--remote-control`) lets claude.ai control a local session; its protocol is not public, and I did not study it.
- Copy: the three-state session signal, a push of the full command list on change, a permission callback as a request from server to client. Avoid: a very wide message union, and provider-shaped (Anthropic API) content as the client contract.

---

## Comparison

| Aspect | opencode v2 | opencode v1 (TUI today) | ACP v1 / v2 draft | pi RPC | pi server (experimental) | Claude Code SDK |
|---|---|---|---|---|---|---|
| Transport | HTTP + SSE; same router in-process | HTTP + SSE; worker RPC in TUI | JSON-RPC over stdio; HTTP/WS is a draft RFD | JSONL over stdio | Length-prefixed CBOR over any byte stream | NDJSON over stdio |
| Who starts whom | Server is separate; clients attach | Same | Client spawns agent | Client spawns agent | Clients attach to a server | Host spawns CLI |
| Multi-client | Yes (any HTTP client) | Yes, but no replay | Not in practice (stdio) | No | Yes (attachments) | No |
| Join / first state | GET session + messages; or replay from start | Subscribe, then refetch lists | `session/load` or v2 `resume` + `replayFrom:start` replays all as updates | `get_state`, `get_messages` | Snapshot, then buffered updates | `getSessionMessages` from transcript |
| Replay after a point | Yes: `?after=seq`, gap-free | No | No (cursor reserved for later) | No | No automatic replay | No |
| Prompt response | "Admitted" | Created message | v1: end of turn; v2: user `messageId` | `disposition` | App-defined | Stream until `result` |
| Busy state | `session.status` events | same | v2 `state_update` running/idle/requires_action | `agent_settled` | App-defined | `session_state_changed` idle/running/requires_action |
| Command list | `GET /api/command` (templates) | `GET /command` | Pushed `available_commands_update` | `get_commands` | App service | `supportedCommands()` + `commands_changed` |
| Command execution | `POST /session/:id/command` (template) | same | `/name` text in prompt | `/name` text in prompt | App service | `/name` text in prompt |
| Compact / undo | Typed routes | Typed routes | Not in core (compaction update is Preview) | `compact` verb; `fork` | App service | Built-in commands; `rewind_files` control |
| Content blocks | text, reasoning, tool (+ user files) | 12 part types | text, image, audio, resource_link, resource; tool content: content, diff, terminal | text, image, thinking, toolCall | App-defined | Anthropic API blocks |
| Update model | Durable events projected to messages | Part upserts + text deltas | v2: ID-keyed upserts + append chunks | start/delta/end per content index | Snapshot + delta | Whole messages + raw stream deltas |
| Stability | "Experimental" | Current | v1 stable; v2 draft | Stable doc | Experimental | Stable, versioned SDK |

## Recommendation for Helyx

1. **Own the native contract. Shape it like ACP v2. Do not adopt ACP as the wire.** ACP is the widest standard (Zed, JetBrains, neovim, and most agents use it). But its main transport assumes the client starts the agent over stdio. Its remote transport is a draft with no resumption, and its replay is "all or nothing". Helyx needs a server that owns sessions, many clients per session, and gap-free reconnect. ACP v2 cannot give that today.
2. **Take the event vocabulary from ACP v2.** Use agent-owned message IDs, ID-keyed upserts with append chunks, `tool_call_update` with `kind`, `status`, `locations`, and content items (`content`, `diff`, `terminal`), diffs as `changes` plus optional `git_patch`, permission requests with `title` and `subject`, `available_commands_update`, `usage_update`, and `state_update` (`running | idle | requires_action`). Claude Code uses the same three states. Reason: a later `Helyx.Transport.ACP` plugin becomes a thin mapping. Zed, JetBrains, and neovim can then drive Helyx with no new client code.
3. **Take the join and replay model from opencode v2.** Give each session event a durable, per-session sequence number. Join = one `GenServer.call` to the session process that returns `{snapshot, seq}` and subscribes the caller in the same call. Reconnect = "events after `seq`". On the BEAM, one call to the session process serializes snapshot and subscription, so no event can fall between them. Over a network, use the opencode rule: subscribe first, then read after `seq` from the store.
4. **Keep operations typed; keep commands as data.** `prompt` (returns an admitted message ID, like ACP v2, opencode v2, and pi `disposition`), `interrupt`, `compact`, `revert`, `respond_permission`, `set_config`. The server lists commands with `name`, `description`, and input hint. A command runs as `/name args` inside `prompt` (ACP, pi, Claude Code) or by name. Client-only actions such as theme or help stay in the client. Do not copy opencode v1's `/tui/*` routes.
5. **Mark the gaps.** ACP v2 fields can still change. Pin to the published `v2.0.0-alpha.5` schema names, and put the ACP mapping behind its own plugin so a change stays in one place. For SwiftUI, three community Swift ACP SDKs exist. They help only if Helyx later exposes ACP over a network transport.

## Unverified items

- The Claude Code `--replay-user-messages` flag, and the Remote Control protocol.
- Whether opencode v2 has a single "snapshot plus seq" call. I found none in `protocol/src/groups/`.
- How each opencode TUI tool renderer reads the `structured` tool field. I did not audit the renderers.
- ACP client and agent lists are self-reported in the ACP docs. I did not check each implementation.
