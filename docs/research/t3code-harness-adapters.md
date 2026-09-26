# How t3code drives Claude Code and Codex

Research for the design of the harness providers. Facts read on 2026-09-26 from the source of `pingdotgg/t3code` at commit `95030dc674883f0f2a7fd034b32ce742c8cf55d0`, and from two dependencies on npm: `@anthropic-ai/claude-agent-sdk@0.3.276` and `@effect/platform-node-shared@4.0.0-rc.115`. Nothing here was run. The protocol facts of the two programs are in `claude-code-stream-json.md` and `codex-app-server.md`.

Path abbreviations: `CA` is `apps/server/src/provider/Layers/ClaudeAdapter.ts`, `CR` is `.../CodexSessionRuntime.ts`, `CX` is `.../CodexAdapter.ts`, `PS` is `.../ProviderService.ts`, and `P` is `packages/effect-codex-app-server/src/protocol.ts`.

## Shape

- Both harnesses run as **one process per session**, not per turn.
- Claude runs through the Agent SDK `query()`. The prompt is a long-lived async iterable that reads from an unbounded queue (`CA:4416-4422`, `CA:4981`).
- Codex runs as `codex app-server`, started through Effect `ChildProcess`. The handshake is `initialize` with `capabilities.experimentalApi: true`, then `initialized`, then `thread/start` or `thread/resume` (`CR:1335-1360`, `CR:2481-2510`).
- Auth is the user's own CLI login. For Claude, t3code sets `CLAUDE_CONFIG_DIR` and never `HOME`: a changed `HOME` moves the macOS keychain lookup and gives "Not logged in" (`Drivers/ClaudeHome.ts:36-55`). For Codex, it sets `CODEX_HOME` and expands `~` itself (`CR:1325-1331`).

## Input during a turn

- **Claude:** a message sent while a turn runs goes into the same queue and continues the same turn id (`CA:5143-5150`, `CA:5210`). The user line of a new turn gets `uuid` equal to the turn id, which rollback uses (`CA:5262-5265`).
- **Codex:** every message is a `turn/start`, even while a turn runs (`CR:2586`). `turn/steer` is not used.

## Interrupt

- **Claude:** an interrupt does not call `query.interrupt()`. It closes the session, and the next message resumes it (`CA:5276-5284`). The comment gives the reason: "interrupt() can acknowledge while resumed background tasks keep the CLI alive. Stop is a hard session boundary."
- **Codex:** the interrupt works in this order (`CR:2614-2650`):
  1. Settle every pending approval and user-input request.
  2. Send `turn/interrupt` to each running child turn: a 3 s timeout each, 8 at a time, 10 s in total.
  3. Send `turn/interrupt` to the parent turn.
  The process stays alive.

## Stop and process tree

- **Claude:** the SDK `close()` ends stdin, waits 2 s, sends `SIGTERM` to the pid only (not the group), and sends `SIGKILL` after 5 s more (`CA:4257-4268`, SDK `core.mjs`).
- **Codex:** Effect starts the child `detached`, so it has its own process group. When the scope closes, Effect sends `SIGTERM` to the group, then `SIGKILL` 2 s later (`CR:60`, `NodeChildProcessSpawner.js:278-350`). The close settles pending requests as `cancel` and does not send `turn/interrupt` first (`CR:2522-2540`).
- **No watchdog.** A `SIGKILL` of the t3code server leaves every harness process running.

## Approvals

- Four runtime modes: `approval-required`, `auto-accept-edits`, `auto`, and `full-access` (the default) (`packages/contracts/src/orchestration.ts:128-138`).
  - For Claude they map to the permission modes (`CA:4867-4882`).
  - For Codex they map to `approvalPolicy`, `sandbox`, and `approvalsReviewer`. All three are sent on every resume, because an omitted value stays from the earlier run (`CR:515-587`).
- **Claude `canUseTool`** (`CA:4651-4815`) parks each request as a waiter and emits `request.opened`. The rules:
  - `acceptForSession` rescopes the SDK suggestions to `destination: "session"`.
  - An abort of the SDK signal settles the request as `cancel`. The code checks `signal.aborted` again after it adds the listener, so a late abort is not lost.
  - `AskUserQuestion` answers are keyed by the question text (SDK 2.1.121 and later).
- **Codex:** handlers exist for `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `mcpServer/elicitation/request`, and `item/tool/requestUserInput`. Any other request gets `methodNotFound` (`CR:2105-2398`).
- **On close:** both adapters settle every pending request as `cancel` (`CA:4295-4320`, `CR:2527-2528`).

## Tools t3code gives the harnesses

- One HTTP MCP server in the t3code process, at `/mcp`, named "T3 Code" (`mcp/McpHttpServer.ts:662-672`). It serves both harnesses. Its tools cover a preview browser, devices, and pull requests.
- **Auth for `/mcp`** (`mcp/McpSessionRegistry.ts`): each thread gets a random token. The server stores only its SHA-256 hash. The token is the only guard on `/mcp`.
- **How each harness gets the server:**
  - Claude gets `mcpServers["t3-code"] = {type: "http", url, headers}` (`CA:4941-4952`).
  - Codex gets `-c mcp_servers.t3-code.url=...` and a bearer token in the environment (`CX:2296-2310`).
- Codex `dynamicTools` is not used.

## Resume

- **Claude:** the cursor is `{threadId, resume, resumeSessionAt, turnCount, turnStartMessageIds}`. A new session chooses its session id before start (`CA:4413-4415`, `CA:4933`).
- **Codex:** the cursor is `{threadId}`. When `thread/resume` fails with a "not found" text, t3code starts a new thread **with no replay** (`CR:61-68`, `CR:702-787`).
- **Recovery is lazy.** The next send finds no live session and starts one from the stored cursor (`PS:1235-1320`).

## Weaknesses seen in the source

- **No limits.** Queues and the stdout line buffer have no limit (`CA:2109`, `CA:4416`, `CR:1312`, `P:180`, `P:405-418`).
- **No timeouts.** Only the Codex child interrupts have one. Other RPC waits, including the parent `turn/interrupt`, have none (`P:449-466`).
- **Wrong exit kind.** A crash of the Claude process is reported as `exitKind: "graceful"` (`CA:4336-4347`).
- **Crashed Codex session (likely, not confirmed end to end).** After a crash of the Codex process, `hasSession` seems to stay true, so the lazy recovery does not run (`CX:2708-2709`).
- **Slow tool-input parsing.** Partial tool input is parsed again in full on each delta: O(n²) for a large `Write` (`CA:2957-3033`).
- **Name heuristics.** Tool types are chosen by substrings of the tool name (`CA:1027-1075`).

## Worth copying

- **Settle before interrupt.** Settle each pending request before an interrupt and on close.
- **Send overrides on every resume.** Send the approval policy, the sandbox, and the reviewer each time.
- **Choose the session id before start.**
- **Classify an abort by `terminal_reason`,** not by error text (`CA:595-618`).
- **Keep a short stderr tail.** Strip ANSI and keep only `ERROR` lines that are not known to be harmless (`CR:682-700`).
- **Probe Claude without a model call.** A prompt iterable that never yields lets t3code read `initializationResult()` (account, commands, models). The probe has a 25 s timeout and a 5 min cache (`ClaudeProvider.ts:319-397`).
