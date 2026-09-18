# Review: TUI and the helyx Mix task (issue #9)

Scope: the working-tree diff for issue #9 — `plugins/tui` (`Helyx.TUI`, `Helyx.TUI.ViewModel`), `apps/coding_agent` (`CodingAgent`, `Mix.Tasks.Helyx`), the shared `Helyx.Message.add_block/2` move, the feature doc TUI section, root `mix.exs` and `.credo.exs`.

Process: `/ship` — simplify (4 agents), then three review axes (standards, spec, failure-path), then consolidated fix-round reviews per the small-diff scaling rule, each fix round targeting the named invariant.

## Round 1 — simplify

Applied: composer reworked onto the stateful `ExRatatui.Widgets.TextInput` (cursor, Home/End, paste); shared `Helyx.Message.add_block/2` used by both the session and the view model; `attach_result` matches the last cell only (tools run serially); `with`-chains in `CodingAgent.run/1` and `Helyx.TUI.run/1`; per-frame wrapping bounded by a tail-take of the last `height` cells; the session pid bound outside the abort Task closure.

Skipped: none.

## Round 2 — three axes

### Standards

1. Both `ponytail:` markers in `plugins/tui/lib/helyx/tui.ex` named no ticket. **Fixed**: issues #39 (transcript scrollback) and #40 (wrap by display width) created and named in the markers.
2. Numeric limits (4-line tool-result cap, width wrap) tested only over the limit and only with ASCII. **Fixed**: at-limit, under, over, trailing-newline, and multibyte tests added.
3. Judgement call, **accepted**: `Helyx.TUI` lives in `plugins/tui` but is a client, not a Core plugin. The feature doc records the decision; forcing a Transport interface with one pass-through implementation would fake an extension point that does not exist. Revisit if the repository-layout wording in AGENTS.md causes confusion.
4. Judgement call, **accepted**: `transcript_lines/2` is `@doc false` public for tests. Extract a formatter module if rendering grows.

### Spec

1. Feature doc said tool results render "at most four lines"; the code renders four content lines plus a truncation row. **Fixed**: doc wording corrected.
2. `[delta] = Map.to_list(data)` crashed the TUI on a malformed `message_update`. **Fixed** (see rounds 3–4, fold totality).
3. `Helyx.TUI.run/1` returned `:ok` on any DOWN reason, so a TUI crash exited `mix helyx` silently. **Fixed**: `:normal` maps to `:ok`, everything else to `{:error, reason}` (a clean `{:stop, state}` exits the ExRatatui server with `:normal`).
4. Acceptance box "a session from this repository completes a multi-step task against OpenCode" is **open**: it needs `OPENCODE_API_KEY` and a human terminal, neither available in this environment. Recorded in the devlog.

### Failure path

1. A 4-line tool result ending in `\n` rendered "… 1 more lines" (the empty string after the final newline counted, and the grammar was wrong). **Fixed**: trailing newlines trimmed before splitting; truncation row pluralized. Boundary tests added.
2. False comment: "every cell yields at least two lines" — an assistant message of only tool-call blocks yields one. **Fixed**: comment corrected; the tail-take fill argument needs only one line per cell.
3. Enter with a dead session crashed the TUI with `noproc`. **Fixed**: `mount/1` monitors the session (via new `Helyx.Session.pid/1`) and the TUI exits `{:session_down, reason}` on DOWN, which `run/1` now surfaces.
4. `transcript_lines/2` crashed at width 0. **Fixed**: the clamp moved into `wrap/2`, covering every caller.
5. `mix helyx` raised a raw `OptionParser.ParseError` on a bad flag, silently dropped extra positional arguments, and accepted a nonexistent directory. **Fixed**: all three validated with `Mix.raise` before `app.start`, with tests.

## Round 3 — fix-round review (consolidated)

Invariants targeted: truncation bound, fold totality, failure surfacing, CLI validation, width clamp.

1. `mount/1` silently skipped the monitor when the session was already dead, so the TUI hung idle forever. **Fixed**: a nil pid exits `{:session_down, :noproc}`, with a test.
2. The `message_update` guard checked key shape but `data: nil` still crashed `Map.to_list/1`. **Fixed** — and because this was the second finding on fold totality, the round also audited every clause head and guarded `queue_update`, which accepted any `data`.

Clean: truncation bound across empty/only-newlines/interior-blank/multibyte outputs, width clamp for 0 and negative, DOWN handling in local mode, abort Task isolation, CLI validation for every bad invocation.

## Round 4 — mechanism fix for fold totality

The final review found the same mechanism a third time: key-shape guards let malformed *values* through (`%{text_delta: 123}`, `%{tool_call: :junk}`, `%{steers: %{}, follow_ups: 0}`). Per "two findings on one mechanism stop the patching", the mechanism was fixed: every `apply/2` clause head now matches key and value shape (`is_binary` deltas, `%Message.ToolCall{}` structs, `is_integer` queue counts), `Map.to_list` is gone, and anything malformed falls to the catch-all. The malformed-event test enumerates all reproductions. Verified closed by the same reviewer.

## Round 5 — external reviews of PR #43 (Codex, Greptile)

1. Codex P1: quitting mid-turn leaves shell process groups running after the VM exits (reproduced with a surviving `sleep 60`). **Fixed**: `CodingAgent.run/1` calls `Session.abort/1` — the only path that makes the hands kill the groups and wait — after the TUI returns, on every quit path.
2. Codex P2 and Greptile P1 (both reviewers, and the fix-round agent reproduced it): the caller of `Helyx.TUI.run/1` is linked to the TUI, so an abnormal exit killed it through the link before the `{:error, reason}` return. **Fixed**: `Process.unlink/1` after the monitor.
3. Greptile P1, security: model text and tool output reached `Span.content` with no control-character filtering, so ESC/OSC/CSI sequences in a file could manipulate the terminal. **Fixed**: `sanitize/1` at the single render choke point (`styled_lines/3`) — invalid UTF-8 scrubbed, tabs become spaces, other control characters drop. Tested with OSC/CSI/BEL/CR and a raw `0x9B` byte.
4. Greptile P2: the event catalog said ten events and omitted `queue_update`. **Fixed** — and the catalog also listed `tool_execution_update`, which `Helyx.Event` never had (an earlier record notes it is not emitted). The line now matches the type union exactly: ten events including `queue_update`, turn id nil on the queue drain.
5. Codex P2, **deferred**: pasted text loses newlines and tabs in the single-line composer. The honest fix is a multiline composer, which renegotiates Enter-to-send. Ticket #44.
6. Greptile P2, **deferred**: steers on harness turns must abort-and-resend per the feature doc. No harness provider exists yet; the path lands with the `ClaudeCode`/`Codex` provider work.

## Round 6 — fix-round review of round 5

1. A dead session made the new quit-path `Session.abort/1` exit `:noproc` and crash `run/1`. **Fixed**: the abort is wrapped in `try/catch :exit`. The underlying leak — the hands die through the session link without killing their OS groups, so nothing cleans up on a session crash — predates this branch and is ticket #45.
2. The first fix for the linked-exit finding (trap exits in `TUI.run/1`) swallowed `:EXIT` messages from other links, such as Core, leaving them in the caller's mailbox after the flag restore. **Fixed**: reverted to the reviewer's prescription, monitor plus unlink.
3. `sanitize/1` raised `ArgumentError` on invalid UTF-8 (bash output is arbitrary bytes; a raw `0x9B` is a one-byte CSI). **Fixed**: `String.replace_invalid/2` runs first, with a test.
4. The corrected doc line said "Eleven events" and still listed the nonexistent `tool_execution_update`. **Fixed** against the `Helyx.Event` type union. Verified closed by the same reviewer.

## Round 7 — session persistence and resume (Greptile P1 on PR #43)

Change under review: `mix helyx` always passes `sessions_dir` (default `~/.helyx/sessions`), a `--resume` flag resumes the most recent session for the directory (saved model wins; `--resume` with `--model` is a `Mix.raise` before `app.start`), and `Helyx.Session.model/1` supplies the TUI status-bar model. One consolidated agent over simplify, standards, spec, and failure paths.

1. `Session.model/1` on a session that died after `start_session` exited `{:noproc, _}` raw, skipping the `{:error, reason} -> Mix.raise` surface. **Fixed**: `fetch_model/1` in `CodingAgent` catches the exit and returns `{:error, {:session_down, reason}}` through the `with`.
2. `Path.expand("~/.helyx/sessions")` with `HOME` unset raises a raw `RuntimeError` inside `start_session`. **Accepted**: the terminal state is safe (the TUI has not started), and a machine without `HOME` cannot run the agent usefully.

Clean: no fileless path remains through `Mix.Tasks.Helyx.run`; resume restores transcript and model and the status bar shows the saved model; the flag conflict raises before `app.start`; empty and corrupt session files and an absent provider all reach `Mix.raise`; 200 stop-then-resume iterations hit no Registry clash.

## Round 8 — fix-round review of round 7

Invariant: every failure between `start_session` and the TUI surfaces through `{:error, reason}`, never a raw exit.

1. The invariant broke one step later: a failed `Helyx.TUI.run/1` init (session dead pre-mount, or no TTY) killed the linked caller raw on OTP 28 before `start_link` returned (reproduced 300/300). **Fixed**: `run/1` traps exits for just the start window and restores the flag before blocking; a crash inside the window is flushed by pid after the DOWN. This narrows round 6's objection to whole-run trapping: no `:EXIT` residue survives the window, and other links keep their kill semantics while the TUI runs. The verifying round proved the first version's error-branch flush was dead code — `proc_lib` unlinks and flushes the child's exit before `start_link` returns an error — and that it could eat an unrelated `{:EXIT, ...}` from an already-trapping caller; it was deleted.
2. Rebase fallout, found by the plugin suite: the sanitize test expected the raw `0x9B` byte stripped to `""`, but `Message.tool_result` now scrubs invalid bytes to `�` upstream (master's UTF-8 work). The invariant — no control characters or raw bytes reach the terminal — holds; the expectation now follows the real pipeline (`"  a�b"`).
