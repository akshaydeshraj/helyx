# Review: delete inner defensive code (#143)

Date: 2026-09-26. Base: `origin/master` at 706ddd0. Ticket #143, findings A1, A3 to A6, E1, E2, and E3 of `docs/reviews/2026-09-26-boundary-review.md`. The owner decided E1 and E3 on the ticket: delete both.

## Invariant

Each value is checked once, at its boundary, and inner code trusts that check. The boundaries of this change are the public API of `Helyx.Session` (client text: `String.valid?/1` in `prompt/2`, `steer/2`, `follow_up/2`), `ModelRef.parse/1` (model refs), `Helyx.Session.Stream` (provider stream events, and the terminal cap at the end of `run/1`), the hands (the crash reason of the stream Task of an external turn, capped where the hands make it), and the `:DOWN` clause of the session (the crash reason of a local turn). Core events reach the TUI only from the session, so `Helyx.TUI.ViewModel.apply/2` trusts their shapes. An unknown message to the session, or an event of another shape in the TUI, is a bug and crashes.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (4 agents): reuse 0, efficiency 0, altitude 1, simplification 5.

- Applied: the comment in `Hands.outcome/3` now names both places that cap a crash reason. `send_error/1` of the TUI had one clause left, so the string is inline. The `encodable?/1` doc no longer compares with the deleted `valid_utf8?/1`.
- Skipped: a shorter comment in `Group.release/4`. The ticket (E2) asks for this text. The comment on the E3 removal in `Stream.external_event/1` stays, because it says why the id has no check. The doc of `Hands.cancel_response/2` still lists `:no_reply`, which is correct for the function. One helper for the three `String.valid?/1` checks in `Helyx.Session`: they are older code, out of scope. A shared cap of the crash reason: the two places are two different processes, and each caps where it makes the terminal.

Standards: 6 findings.

- Fixed: `coding-agent.md` still listed the status text `not sent: not valid UTF-8`, and the `Helyx.TUI` moduledoc still named invalid text as a reason for a rejected send.
- Fixed: the bounds table did not say what happens to an unknown message now. A new row says that the session crashes, and that the TUI crashes on an event of another shape.
- Rejected: "a stale `:stream_end` crashes the session". The clauses for a message of a turn that is not current (`:tool_result`, `:stream_event`, `:stream_end`, `:rejected_call`) match in every state. The failure-path axis confirmed this.
- Accepted as is: the hands depend on which terminals `Stream.run/1` caps (recorded in `session-stream.md`); the `Session` specs keep `:invalid_utf8`, because `Session` is a boundary.

Spec: 3 findings.

- Fixed: the integer row of `coding-agent.md` said that the reason of a Task exit gets the cap in the session process. It now names the session for a local turn and the hands for an external turn.
- Reading of "the stream caps each terminal once": the terminal cap at the end of `Stream.run/1` is the one cap of each terminal; the second cap in the session is gone. The cap of the usage in `capped_usage/1` stays, because it must run before `encodable?/1`.
- The test "only a tool result message with a binary call id attaches" in `view_model_test.exs` is deleted. The ticket does not name it by line, but it is an A3 malformed-path test: every case in it is a shape that Core never makes (a `nil` call id, a user message in `:tool_execution_end`), and it tested only the guard and the catch-all that A3 deletes.

Failure-path: 0 findings. The agent listed every message a live session can receive and tested three race cells with suspended processes (an abort while the local Task replies, a Task exit during the release of an abort, an external stream that ends during a steer). The session lived in each cell. Every `emit` of the session has a matching `ViewModel.apply/2` clause.

## Round 2 (reduced)

The fix changed 2 lines in one code file (the `Helyx.TUI` moduledoc) and Markdown. It adds no function and changes no arity. So the round is reduced: spec and failure-path.

Spec: 0 findings. No doc, moduledoc, or comment in scope still describes a deleted check.

Failure-path: 1 finding, not fixed here. A `/model` switch to a provider whose `turn/0` is bad crashes the TUI in `model_error/1` with `{:bad_provider_turn, id}`. This fault is on `origin/master` too. It is finding D3 of the boundary review, and ticket #145 fixes it.

## Precommit

`mix precommit` passed in the root, `plugins/bundled`, and `apps/coding_agent`.

## Orchestrator

- Codex adversarial review, round 1: no finding. Precommit passed after the rebase on #142.
- Accepted: the extra deleted ViewModel test (it tested only the guard and the catch-all that A3 deletes), and one cap per terminal in `Stream.run/1` (the usage cap before `encodable?/1` stays).
- Not fixed here: the `/model` crash on a bad `turn/0` is #145.
