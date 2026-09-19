# Review: ticket #83, a cell added during a tool run hides the tool result

Date: 2026-09-19. Scope: `Helyx.TUI.ViewModel` (`apply/2` for `tool_execution_end`, `attach_result/2`), its tests, and `docs/features/coding-agent.md`.

## Invariant

Only a `tool_execution_end` event whose message has the role `tool_result` and a binary `tool_call_id` attaches. It attaches only to the newest open tool cell with the same call id, wherever that cell is. A cell that has a result never changes. Any other event or message changes no cell and does not raise. Entry points: `ViewModel.apply/2`, `notice/2`, `reject/2`, `clear_reason/1`. Documented exception: the content of the result message is not checked, see "Outside the ticket".

The session runs tool calls one at a time: `lib/helyx/session.ex` starts the first call, records its result, then starts the next. On abort it emits `tool_execution_end` for each open call, also for a call that never started. The fold does not depend on that order.

## Bounds sensor

All rounds: `bounds sensor skipped: TYPESAFE_API_KEY is not set`

## Simplify

Round 1: 1 applied (the test for an unknown call now uses `tool_end/1`). Not applied: merge the ok and error tests (the ticket asks for both), delete the session order test (the task asks for a test of the real order), a single-pass recursion (longer, constant factor only). Altitude: clean. The altitude agent stopped at a usage limit and was run again.

## Round 1 (full)

- Standards: `tool_end/1` was between tests. Moved to the other helpers. Fixed.
- Standards: a 50-word sentence in the TUI section. Split. Fixed.
- Standards: two tests hold more than one scenario. Accepted: each scenario is small and has a comment.
- Spec: all 4 acceptance boxes met. Low: the bounds row said "No limit is set" and cited #83. Changed to "accepted as unbounded, like the composer (#29)". Fixed.
- Failure-path: no defect from the diff. One older edge, reproduced: an open cell with a nil call id took a user message, because the nil ids matched. Fixed with a guard `is_binary(id)` on the clause, plus a test.

## Round 2 (reduced)

The fix: 8 lines added and 1 removed in one code file, no new function, no change of arity or spec. Round type: reduced (spec and failure-path).

- Spec: a second path on the same clause. A user message with `tool_call_id: "c1"` attached to the open cell "c1", because the clause did not check the role.
- Failure-path: the same case, as an observation.

This is the second finding on one mechanism, the shape check of the clause. The mechanism was fixed, not the path: the clause head now matches the role `tool_result` and a binary call id, which is the shape `Message.tool_result/2` makes. One test covers the nil id, a tool result with a nil id, and a user message with an equal id.

## Round 3 (full, by the two-findings rule)

- Simplify, 4 agents: clean. The two optional test cuts of round 1 came again and stay not applied.
- Standards: no rule broken. 2 optional points, not applied: the single-pass recursion (see Simplify), and the position of one test comment.
- Spec: clean on the invariant; both reproductions and 7 more shapes do not attach. All 4 acceptance boxes met. Minor: #29 is the composer ticket, not a cell list ticket. The row now also says that a limit on the cell list is accepted for checkpoint one.
- Failure-path: no path breaks the invariant. 1 older defect outside the ticket, see below. 1 comment said more than the check does. The comment now says that the content is not checked. This is a comment-only change, so no further round was run.

## Outside the ticket

- Accepted by the orchestrator with no ticket: `Helyx.TUI.transcript_lines/2` raises on a tool cell whose result has malformed content (`content: nil`, a string, or a `Text` with nil text). The raise is in `Message.text/1` and the render, not in the fold, and master has it too. No session path makes such a message: `Message.tool_result/2` always makes a list of `Text` with binary text.
- Accepted by the orchestrator with no ticket: a limit on the TUI cell list. The list, the append, the search, and the render are all linear in the cell count.
