# Review process hardening after ticket #4

Ticket #27. Ticket #4 (abort with full cleanup) took six review rounds on PR #22 before one weakness — the process group id lived only inside the tool Task — was fixed structurally. Full record: `docs/reviews/2026-09-17-abort-cleanup.md`. This log lists the rounds and the rule, added today, that would have stopped each one.

## The six rounds

1. **Internal three-axis review.** Found nothing. It accepted the spawn-to-`Port.open` race by window size ("microseconds against a human-initiated abort") and named the structural fix as a later upgrade path. Stopped by: the race rule (a race is closed structurally or written as "open, ticket #N", never accepted by window size) and the ownership table (a group held by a Task is a design flag raised before implementation).
2. **Human PR review.** A background child left by a completed call survived the abort; the hands only scanned live Tasks. Stopped by: the state table in the failure-path brief — the cell (call completed, children running) x (abort) was never enumerated.
3. **Bot re-reviews of the fix.** The `Port.info/2` nil guard skipped the group kill; the temp-file handoff that replaced it was symlink-racable and leaked on abort. The rounds were "reviewed by hand per the diff-size rule", a rule that does not exist. Stopped by: the no-exemption rule (nothing is reviewed by hand) and the invariant-driven fix brief (the review would have hunted other paths that lose the group id, not just the nil-guard reproduction).
4. **First Codex review.** The shell exits before the completion kill, and an abort in that interval brutal-kills the Task holding the group id. Third finding on the same mechanism. Stopped by: the two-findings rule — the patching should have ended one round earlier, at the second finding on group-id-in-Task, with the hands-registered-groups fix (ADR 0004) that this round finally shipped.
5. **Second Codex review.** A scheduler-starved Task leaves the spawn-to-registration window open; the port scan cannot cover it. Stopped by: ADR 0004's registration-before-work invariant — the stdin handshake that closes this window is what "registered with the hands before the external work starts" requires, and the invariant-driven brief would have asked for exactly this path.
6. **Greptile re-review.** `deliver/3` published the result before the killed group was gone, so the next call could race the dying group. Stopped by: the state table — the cell (group killed, still dying) x (delivery) was a listed external state crossed with a listed BEAM event.

## What was changed

- `docs/features/TEMPLATE.md`: ownership table (created by, held by, released on normal end, on holder crash, on abort) with the Task-holder design flag.
- `docs/agents/review-checklist.md`: "Races and resource ownership" section with the race rule and the two-findings rule; a spec-axis line ties the ownership table to the diff.
- Ship skill: the no-exemption rule, the state-table instruction in the failure-path brief, and the invariant-driven fix brief with the two-findings stop.
- `docs/adr/0004-os-resource-ownership.md`: OS resources are owned by long-lived processes, never by Tasks. ADR 0003 links to it.

## What is next

- Apply the ownership table retroactively to the abort feature doc when the harness tickets touch it.
