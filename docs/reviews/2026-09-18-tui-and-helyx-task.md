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
