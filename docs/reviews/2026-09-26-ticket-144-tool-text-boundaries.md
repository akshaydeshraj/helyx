# Review: repair tool text at the two boundaries (#144)

Date: 2026-09-26. Base: `origin/master` at e441ae2. Ticket #144, finding B of `docs/reviews/2026-09-26-boundary-review.md`. The owner decided on the ticket: two boundaries.

## Invariant

Tool text is made valid UTF-8 once, at its boundary, and inner code trusts it. The two boundaries are the hands (`scrub/1` in `Helyx.Session.Hands`, for the output of a tool of the session) and `Helyx.Session.Stream` (`scrub/1` in `external_event/1`, for a Claude Code or Codex result, after the 65,536-byte check). `Helyx.Message.tool_result/2` and the TUI (`sanitize/1`) do not repair the text again. The other text that reaches the TUI render is checked at its own boundary: prompts in `Helyx.Session`, deltas in the stream, model refs in `ModelRef.parse/1`, and the session file in `JSON.decode/1`. Tool call lines and error notices are cut and repaired by `cut_line/1` of the view model.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (4 agents): reuse 1, simplification 3, efficiency 0 (one optional nit), altitude 1.

- Applied: the repair in the stream has the name and the shape of `scrub/1` in the hands, and its comment names the other boundary. The TUI comment no longer lists the two places. Line 141 of `coding-agent.md` points to the row "tool result text validity" and does not repeat it.
- Skipped: one shared helper for both `scrub/1` copies. The owner chose two boundaries, and a call from the stream into the hands adds a dependency for one line. Skipped: `String.valid?(text, :fast_ascii)`. The hands use the default algorithm, and both boundaries keep one rule.

Standards: 0 hard findings, 3 judgement calls.

- Kept: the new stream test overlaps with `session_test.exs` ("the size check runs before the UTF-8 repair"). The ticket asks for a stream test at the new boundary.
- Kept: the sentence on the repair is in the comment block above the first `external_event/1` clause. That block describes all the events of an external turn.
- Accepted: the error status is not tested at the stream boundary. `scrub/1` has one clause for both statuses, and the failure-path agent probed it.

Spec: 0 blocking findings. The invalid-bytes part of the TUI test moved to the stream test, as the ticket permits ("moves"). The TUI test now checks that U+009B drops. The agent traced every text source of `styled_lines/3` and found each one valid.

Failure-path: 0 findings. Probes through `Stream.run/1` with an external provider: an error result with invalid bytes is repaired; 65,537 invalid bytes fail the turn with `{:tool_result_too_large, 65_537, 65_536}`; a partial character at the limit passes and grows to 65,538 bytes, within the stated growth of three times. `JSON.decode/1` rejects invalid bytes in a session file.

Step 2 changed no code, so there is no rerun round.

## Precommit

`mix precommit` passed in the root, `plugins/bundled`, and `apps/coding_agent`.
