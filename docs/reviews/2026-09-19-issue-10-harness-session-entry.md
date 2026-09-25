# Review: ticket #10, part one: the `harness_session` entry and the stream-json research

Scope: `Helyx.SessionFile.append_harness_session/3`, the restore of the last harness session id of each provider in `resume/3`, the bounds row in `docs/features/coding-agent.md`, and `docs/research/claude-code-stream-json.md`. The provider itself is not in this change: it waits on interface decisions (see the ticket).

Invariant: `resume/3` never raises at the caller and never mutates a file that it rejects; a `harness_session` entry whose `id`, `provider`, or `harness_session_id` is missing or not a string is `{:error, {:invalid_file, _}}`; the last entry of each provider is restored; an append moves the leaf.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`

- Simplify (reuse, simplification, efficiency, altitude): 4 agents, all clean. No fix.
- Standards: no hard violation. 4 judgement calls, all fixed: the parameter `provider` holds a provider id, renamed `provider_id`; the `@doc` said "harness program", now the glossary's "external program"; the test id `thread-1` used an avoided word; the doc row said "harness entry". 1 accepted: the type tag occurs in three clauses, the same layout as `model_change`.
- Spec: 2 fixed: a sentence of the new bounds row stated behaviour that no code has yet, now marked as design for #10; the feature doc did not cite the research note for the lost harness session. 2 recorded, not defects of this part: the session does not read `Resumed.harness_sessions` yet, and the future caller must go through `persist/2`.
- Failure path: 0 defects. 2 reproduced behaviours that the doc row already assigns to #10: an id that is not valid UTF-8 raises from `JSON.encode!` and leaves the file unchanged, and `resume/3` restores control characters and ids of any size. The check belongs where the id enters the session from the harness stream.

## Round 2 (reduced: spec and failure path)

Fix counted without tests and Markdown: 10 lines, one code file, no function added, no arity or spec change. Base: the staged round-one tree.

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`

- Spec: both round-one findings closed. 2 more doc sentences fixed (Markdown only): "the reason only as text in `errors`" was false, stderr carries it too; the row named only the writer as not built, not the reader. 2 design gaps recorded for the ticket, not for this change: the harness session id is known only when the `init` line arrives, not "when the first harness turn starts", and the doc does not say whether the turn that finds a lost harness session runs again.
- Failure path: 1 low finding, fixed in the doc (Markdown only): the row said any missing or non-string field is a malformed file, but only `id`, `provider`, and `harness_session_id` are checked; `parent_id`, `ts`, extra fields, and empty strings pass. `model_change` has the same check and had it before this change. The row now states what the code does. 12 probes held, among them a harness line torn at every byte offset and a rejected file that is not truncated.

The last two fixes touch only Markdown, so no further round is due.

Deviation from the skill: the round-one tree was staged, not committed, before the fix, so the rerun agents got the diff of the fix alone from the index.
