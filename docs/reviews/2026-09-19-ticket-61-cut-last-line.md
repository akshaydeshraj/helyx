# Review: ticket #61, a cut last line names no offset

Date: 2026-09-19. Branch `ticket/61-cut-last-line`, base `origin/master` at `23f31b9`.

Invariant: a truncated `:head` notice has the `read again with offset N` clause exactly when lines follow the shown lines.

## Simplify

Four agents: reuse, simplification, efficiency, altitude. Three reported clean.

- Simplification, applied: `notice/2` in `test/helyx/tool_test.exs` had one assertion in two branches. It now computes the expected value and asserts once.
- Simplification, not applied: write `offset_note/2` with a `when last == total` guard. The repeated variable is the pattern-matching form that `AGENTS.md` prefers, and the altitude agent judged the same point "not worth changing".

## Round 1, complete round

Bounds sensor, base `origin/master`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Standards: 0 hard violations, 2 judgement calls (the `if` in the test helper, the repeated variable in `offset_note/2`). Not applied; both are idiomatic and the comment above the function explains the match.
- Spec: all 4 acceptance criteria met. 2 low findings.
  - The `description/0` and the moduledoc of `Helyx.Tool.Read` said without a condition that a truncated result names the offset. Fixed: both now say "when lines follow".
  - No test read a cut last line through the `read` tool. Fixed: a test in `plugins/bundled/test/helyx/tool/read_test.exs`.
- Failure path: 0 reproduced defects over 4,116 generated inputs plus the line limit, the byte limit, offsets past the end, and a file that copies a notice. It named the same `read.ex` text as the spec axis.

## Round 2, reduced round

The fix changed 4 code lines in one code file (`plugins/bundled/lib/helyx/tool/read.ex`, text only). It added no function and changed no arity, return shape, or spec. The two-findings rule does not apply. Thus the round was reduced: spec and failure path, both briefed with the invariant.

Bounds sensor, base `HEAD` with the round 1 change in the working tree:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Spec: 1 finding, docs. The first sentence of the "tool result text" row still gave the rule without the condition. Fixed in `docs/features/coding-agent.md`. This change is Markdown only, so it needs no more rounds.
- Failure path: 2 reproduced findings, both older than this ticket and outside its acceptance criteria. Not applied; reported to the orchestrator.
  - When every line after the shown lines is blank, the named offset returns `""`. Example: 2000 lines, then one blank line. The blank lines are lines by the rule of `truncate/2` ("trailing blank lines count toward the limits"), so the empty read is the true content. If this must change, it needs a decision about how blank lines count. Ticket pending.
  - `Helyx.Tool.Read` ignores an `offset` that is not an integer (`2001.0`, `"2001"`) and reads from line 1 without an error. Ticket pending.
