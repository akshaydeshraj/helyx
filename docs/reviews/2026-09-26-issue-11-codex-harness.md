# Review: ticket #11, the Codex harness provider

Branch `ticket/11-codex-harness`, base `origin/master` (6804b6b). Scope: `Helyx.Provider.Codex`, `Helyx.HarnessIO` (moved out of `Helyx.Provider.ClaudeCode`), the open input of `Helyx.Watchdog`, and the shutdown grace of a harness stream Task in `Helyx.Hands`.

## Round 1 (full)

Simplify ran first (four agents). Applied: the watchdog start, `stop`, and the done `next` clauses moved into `HarnessIO` (`start/4`, `stop/1`, `drain/1`, `remaining/1`); `thread_params/1`; `Map.reject` in `arguments/1`; `Message.user/1` in the tests; the call id variable in `Hands.cancel`. Skipped: a shared test helper module for the two provider tests (outside the diff), a lazy replay encode and a tail-recursive `lines/3` (the same as before the move; not hot), a parallel stream shutdown in the hands (one stream Task per turn), and a check that the 1,000 ms interrupt wait stays under the 2,000 ms grace (both are documented in one bounds row). One simplify change, the removal of `open?` and `calls?`, caused finding F1.

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F1 | failure path, spec | Two tool items that run together: each completion sent a `message_end`, so the second one aborted the open call B, added an empty assistant message, and B's real result was dropped. Reproduced with the fake `codex` in a session | Fixed: `open?` is back; only content since the last `message_end` opens a message. Test "two tool items that run together close one message" |
| F2 | standards | No tests at the limits of `call_id/1` (64 characters) and `tool_name/1` (cut at 64) | Fixed: test at 63, 64, 65, and a multibyte case for both. The name replacement now works per character (`/u`), so `é` gives one `_` |
| F3 | standards | `Hands.stop/1` returns a shutdown mode and clashes with `HarnessIO.stop/1`; `@tools` holds item types | Renamed `shutdown_mode/1` and `@tool_item_types` |
| F4 | standards | The status and subtype cuts, and two error message reads, repeat one shape | `HarnessIO.cap_error/1` takes any value (not text is empty); one `error_message/2` in Codex |
| F5 | spec | The row "wait for an abort" did not count the 2,000 ms stream grace | Row states it: worst abort 22,000 ms |
| F6 | spec | The 64-character name cut has no source | The code comment and the feature doc say it is the Chat Completions limit, not verified for `thread/inject_items` |
| F7 | spec | An abort before the `turn/start` answer sends no `turn/interrupt` | Documented: the release's TERM stops the program then |
| F8 | spec | The effect of an error answer to a server request is unknown | Research note marks it not verified |

Not taken: a shared state struct for the `HarnessIO` fields and a struct for the replay entry (judgement calls; the fields are documented in the module comment, and ClaudeCode used the same tuple before the move).

Fix size, without tests and Markdown: 70 lines in 4 code files, with new functions. Round 2 is a full round.

## Round 2 (full)

Base: the round 1 tree (a temporary ref, `refs/review/t11-round1`). Simplify (four agents) applied: `error_message/1` returns nil and the callers give the default; three asserts in place of one joined with `and`. Skipped: a derived `open?` (the round 3 fix removes the flag), a session-side no-op for an empty `message_end` (a Core change for every provider; the rule is stated in `Helyx.Provider` instead), and a `:persistent_term` regex cache (off the hot path).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F9 | failure path, spec, standards | Second path on the mechanism of F1: calls a and b start, a completes, then text (or a thinking delta, a whole message, or a new call) comes before b completes. The flag `open?` was true again, so b's completion sent a second `message_end`: the session aborted b and dropped its real result, and the text became a message with `:tool_use` and no call. Reproduced in a session with the fake `codex` | The two-findings rule applies, so the mechanism changed. `open?` is gone. The provider keeps the calls of the open message (`calls`), the calls of sent messages with no result (`waiting`), and a queue of held events (`held`). A `message_end` waits in the queue while `waiting` is not empty, and so does every event after it; a result of a waiting call goes out at once and frees the queue; a terminal sends the queue. Tests: "a message that closes before an earlier call's result waits for it" (the provider's order, and in a session every real result joins the transcript before the next message) and "the turn's end sends the held events". `Helyx.Provider` states the rule: one `message_end` per message, only after new content, and only when every earlier call has its result. The feature doc has the held events row in Bounds |
| F10 | standards | The tool name test had no case one under the limit | A 63-character name is tested |
| F11 | standards | `close` names a list of events | Gone with the F9 change |
| F12 | spec | `Helyx.Provider` stated only half of the rule | Both halves are stated (F9) |

Observed, not changed: when a turn ends right after a tool result, the session closes the turn with an empty assistant message (`content: []`, `:end_turn`). This is the session's behaviour before this change, for every harness provider; Codex ends a turn with an agent message in the runs of the research note. The new session test states it.

Fix size, without tests and Markdown: 115 lines added plus removed in 2 code files (`codex.ex` 90 plus 20, `provider.ex` 3 plus 2, a doc comment), 80 without comment and blank lines. New functions, so round 3 is a full round.

## Round 3 (full)

Base: the round 2 tree (`refs/review/t11-round2`). Simplify (four agents) applied: a fast path that sends an event at once when nothing is held; one `emit/2` for every sent event, so one place writes `waiting`; `flush/1` without nested keyword `if`; `translate/2` in the interrupt wait (its events are dropped); `@done` in the tests; the cost of held live text in the bounds row. Skipped: a waiting result through the queue (it would wait behind the `message_end` it frees), and a Core change that keeps calls open across a `message_end` (altitude agent: the provider is the right depth, since only Codex completes items out of order).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F13 | failure path, spec | The program's exit and a line over the cap set their terminal outside the ordering, so the held events were lost: a finished call and its real result never reached the transcript. Reproduced with the fake `codex` for both | `settle/1` in `next/1` sends the held events after every chunk or exit that sets a terminal. Tests "an exit sends the held events before its error" and "a line over the cap sends the held events before its error" |
| F14 | spec | `Helyx.Provider` stated no exception for the end of the call, where a held `message_end` goes out while calls have no result | Stated: at the end of the call a held `message_end` goes out, and the calls with no result are aborted |
| F15 | spec | The Codex bullet said "closed message" where the code means a sent message, and it read against the bounds row | Reworded; the bullet points to the row |
| F16 | standards | The one-character id was not asserted, and the empty id was missing | Both asserted (the empty id becomes a digest) |
| F17 | standards | `decode/2` does no decoding | Renamed `in_order/2` |

Not taken: a ticket number for the held events row (the checklist asks for one; the rows of this kind use "accepted with no ticket for checkpoint one", and the row says so); a struct for the ordering fields and the `{:close, ids, event}` marker (judgement calls; every exit goes through `emit/2`).

Fix size, without tests and Markdown: 28 lines added plus removed in 2 code files, one function added and one removed. Round 4 is a full round.

## Round 4 (full)

Base: the round 3 tree (`refs/review/t11-round3`). Simplify (four agents) applied: `:queue.fold/3` in `settle/1`; `put/2` merged into `in_order/2`; a tighter pattern for the call id. Skipped: one shared helper for the two new tests (small), and held events kept as raw events (the `{:close, ids, event}` marker would reach the session).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

The failure-path axis found nothing: seven probes with the fake `codex` (a terminal in the middle of a chunk, output in the exit wait, an error response, the exit wait timeout, a waiting result in the chunk of an exit, a session that exits with held events, a last line with no newline) were clean.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F18 | spec | A result of a call of a held message went to the back of the queue, behind the `message_end` of a later held message, which waits for it. The session then aborted the call and dropped the real result, and the later text stayed held until the turn's end. Reproduced with the fake `codex` | `hold/2` puts a held result right after its own `message_end` and the results there. Test "a held result goes before a later message's end" (fails without the fix) |
| F19 | spec | The docs did not say that an abort or a steer drops the held events, finished results included | Stated in the Codex bullet and the held events row |
| F20 | standards | `put_one/2` was named after the removed `put/2` | Renamed `order_one/2` |
| F21 | standards | `Helyx.Provider` used the Codex word "held" and an idiom | Reworded: at the end of the call a provider sends every `message_end` that it did not send yet |

Not taken: the ticket number for the held events row (as in round 3); one helper for the shared events of the exit and line-cap tests (small).

Fix size, without tests and Markdown: 26 lines added plus removed in 2 code files, two functions added. Round 5 is a full round.

## Round 5 (full)

Base: the round 4 tree (`refs/review/t11-round4`). Simplify (one agent, four lenses: reuse, quality, efficiency, altitude) applied: a comment for the result with no held `message_end` (a repeat) and for the insert cost. Skipped: `:queue.filter/2` (it puts a result before the earlier results of its message), and a map of held results by call id (about the same code, and it loses the arrival order).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

The failure-path axis found nothing: four probes with the fake `codex` (three held messages with results in reverse order, repeated completions, a terminal with results in the middle of the queue, a result in the chunk of its close), each direct and through a session, were clean, and the `{:close, ...}` marker never reached the output.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F22 | spec | The docs said that at an abort or a steer the held calls get `aborted` results. They get none: the held messages never reach the transcript, and only the calls of sent messages are aborted | Reworded in the Codex bullet |
| F23 | standards, failure path | The new `ponytail:` marker named no ticket (checklist: every marker names a ticket) | Replaced with a plain comment that points to the row "Codex held events" |
| F24 | standards | "can not" in the `hold/2` comment | "cannot" |

Not taken: a struct for the `{:close, ids, event}` marker and a list in place of the queue (judgement calls, as in round 3); the ticket number for the held events row (as in rounds 3 and 4).

Fix size: comments and docs only, no code line changed. No further round.

Precommit fixes after round 5: Credo asked for `-32_601`, and Dialyzer found an improper list in the go-ahead write of `Helyx.Watchdog.start/3` (now a proper list). Two lines, no behaviour change.

## Round 6 (full): orchestrator review after the first commit

The orchestrator found a blocking gap (O1) and asked for three more changes. Invariant: in the normal case (codex responsive), no command that codex started outlives the abort release.

| # | Source | Finding | Resolution |
| - | ------ | ------- | ---------- |
| O1 | orchestrator | Codex runs every command in a process group of its own and ends them itself on TERM in about 0.5 s; a KILL leaves them running. A 500 ms grace before the KILL races that cleanup. Two KILLs raced: the perl watchdog's, when the stream Task's exit closes the port, and the release's | A `:grace_ms` option reaches the perl watchdog (`Helyx.Watchdog.start/4`, `launcher/5`) and `Helyx.Watchdog.Group.release/4`. Codex passes 5,000 ms to both. Tests: "an abort gives the program time to end its commands" (a fake that ends its own-group command after the TERM; it fails with a 500 ms grace), and a test at the grace limit for the watchdog and for the release |
| O2 | orchestrator | An abort or a steer drops the held events, finished results included | Not built. `abort_turn/3` closes the turn when the abort starts, and the session drops every later event of that turn, so a flush from the provider cannot reach the transcript. A fix needs the session to keep a harness turn open until the hands answer, which moves `agent_end` and changes Claude Code too. A design decision; stated as a hole with ticket #112 |
| O3 | orchestrator | The reading of "code lines" | Confirmed: no comments, no blank lines |
| O4 | orchestrator | The unbounded rows had no ticket | The rows "Codex held events" and "Harness tool calls and messages per harness turn" point at #111 |

Simplify (one agent, four lenses) applied: stale arity names, and the release test at a 1,000 ms grace (it saves 4 s). Skipped: one mechanism for both graces (wait for the watchdog before the KILL of the command groups; a redesign of the sweep, and it changes bash).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F25 | failure path, spec | A `:deliver` release KILLs at once. The stream can end by itself while codex runs a command (a line over the cap, the exit wait timeout), and the KILL then leaves the command running. Reproduced for both; the test covers the path of the line over the cap | `Codex.release/3` treats `:deliver` as `:cancel`: TERM, the 5,000 ms grace, KILL. Test "a stream that ends while a command runs gives the program the same time" (fails without the clause) |
| F26 | spec, standards | No test pinned the 5,000 ms: a 500 ms value passed every test | The fake now ends its command 3 s after the TERM; a 2,000 ms grace fails both Codex tests |
| F27 | spec, standards | The row "Codex interrupt wait" still said "500 ms grace" | 5,000 ms |
| F28 | standards | A tuple `{deadline, grace}` only to keep the arity of `sweep`, named `_times` | Two arguments |
| F29 | standards | `@grace_ms` above `@moduledoc false` in `Helyx.Watchdog`, and a comment line of 110 characters | Moved below; wrapped |

Not taken: one attribute for the 500 ms default of `Helyx.Watchdog` and `Helyx.Watchdog.Group` (each module keeps its own default); `start/3` in the rows of bash and Claude Code (still true through the default argument); a note on #111 that it now also tracks the dropped events (for the orchestrator).

Fix size, without tests and Markdown: about 12 lines in 3 code files, one function clause added. Round 7 is a full round.

## Round 7 (full)

Base: the round 6 tree (`refs/review/t11-round6`). Simplify ran with the standards axis (one agent): `own_group_command/2` takes `after_pid`, not `then`, and the line over the cap is built from `HarnessIO.line_max_bytes/0`. Skipped: moving the helper up to the other helpers (layout only).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

The failure-path axis found nothing it could reproduce: a turn error while a command runs, and a session killed while a command runs, both ended the command. `:retry` runs only on handles that a release did not confirm, after its KILL, so it falls in the stuck-codex hole.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F30 | spec | The perl watchdog's grace ends when its direct child exits, not when the group is empty; if the Node wrapper exited before the native binary, the KILL would cut the cleanup short | Checked in the wrapper source (`bin/codex.js` of 0.155.0): it forwards TERM once and exits only after the binary. Recorded in the research note and the "Codex program" row; the watchdog comment states that the wait is for the direct child |
| F31 | spec | The row "wait for a killed process group" still said `:deliver` KILLs at once, with no Codex exception | States that `Codex.release/3` gives a delivery the `:cancel` sequence |
| F32 | failure path | A codex that exits by itself without ending its commands leaves them running | Stated as an accepted hole in the "Codex program" row |
| F33 | spec | The effect of the second TERM (the watchdog's and the release's) on the native binary is not verified | Recorded as not verified in the research note |
| F34 | standards | The rewrapped watchdog comment broke lines early | Rewrapped |
| F35 | standards | `then` shadows the name of `Kernel.then/2`; the cap was a literal | `after_pid`; `HarnessIO.line_max_bytes() + 1` |

Not taken: a note on #111 that it also tracks the events that an abort or a steer drops (the ticket body names only the unbounded rows; for the orchestrator).

Fix size: comments, docs, and tests only; no code line changed. No further round.

## Round 8 (full): orchestrator Codex review, round 1

The orchestrator's Codex review found F36. The same defect was on master in `Helyx.Provider.ClaudeCode.next/1`. Invariant restored: once a deadline has passed, no loop receives another message before it acts on the deadline.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| F36 | Codex (orchestrator) | A `receive` with a matching `{^port, {:data, _}}` never reaches its `after`, even at a timeout of 0. After the terminal, a program that keeps writing kept `done?` false past the exit deadline. The terminal never reached the session, and the release never started. This happened in Codex and in Claude Code | `HarnessIO.overdue?/1` is checked before the `receive` in `next/1` of both providers and in the Codex `await_end/2`. There is one test for each provider: "stdout queued past the exit deadline does not hold the terminal". Each test queues 1,000 chunks after the deadline. Both tests fail when `overdue?/1` always returns false. The "Harness exit wait" row states the rule |
| F37 | spec | The "Codex interrupt wait" row did not say that output cannot extend its deadline | The row now says so |

Base: HEAD 219f161 plus the fix. Simplify ran with the standards axis. Bounds sensor: skipped, because no key is set.

The failure-path axis found no path that breaks the invariant. It ran four throwaway tests with a real flooding program (`exec yes`):
- A Claude Code result: `done` at 5,039 ms.
- A lost session: the fresh run starts with `deadline: nil`, and no stale messages of the old port are left.
- A Codex `turn/completed`: `done` at 5,122 ms.
- A Codex `:shutdown` while the turn floods: `await_end` ends in 1,094 ms, which is inside the 2,000 ms stop grace of the hands.

It found no other receive loop with a deadline: `Watchdog.read_marker/4` and `Bash.collect/3` have no deadline, and `Watchdog.Group` polls.

Not taken:
- A session-level test (spec). A session test cannot put messages into the mailbox of the stream Task. The stream tests show the `{:done, _}` terminal and the stop. `Hands.stream/4` sends `{:stream_end, _}` after the release. The orchestrator can ask for more.
- A test of the overdue interrupt wait (spec). The failure-path probe covered it, and the spec asked only for the terminal test.
- A named `exit_timeout/1` in Codex (standards). This is a judgement call, and it would add a function.
- One clause for `overdue?/1` (standards).
- One shared helper for the two test files (standards). The bundled project has no `test/support`.
- The `Process.sleep(5_100)` coupling to `@exit_wait_ms` (standards). A longer exit wait makes the test fail, so it cannot pass falsely.

Fix size, without tests and Markdown: about 17 code lines in 3 files, with 4 functions added. This round is a full round. Its fixes change only Markdown, so no further round is needed.

## Codex review

- Round 1: 1 finding, confirmed by reading: queued stdout kept `receive` in `next/1` from its `after` clause, so the exit deadline never fired. The same bug was in `Helyx.Provider.ClaudeCode` on master. Fixed in both through `HarnessIO.overdue?/1`.
- Round 2: approve, no findings.
