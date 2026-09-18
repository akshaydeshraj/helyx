# OS resources are owned by long-lived processes, never by Tasks

Ticket #4 took six review rounds on PR #22 (`docs/reviews/2026-09-17-abort-cleanup.md`). The internal three-axis review found nothing; Greptile, Codex, and a human review then found five more windows of one weakness: the process group id lived only inside the tool Task. A Task dies with its state, so every path that killed the Task before delivery took the only reference to the group with it, and each patch left a sibling window open.

## Decision

A process group, port, file handle, or other OS resource that a tool creates is registered with the hands before the external work starts. The hands hold it outside any Task and release it on delivery (however the Task ended), on the holder's crash, and on abort. If registration cannot complete, the external work does not start: either the hands hold the resource before the work runs, or the work never ran.

## Considered options

- Keep the resource in the tool Task and patch each window as a review finds it. Rejected: ticket #4 shows the windows are found one review at a time, and the class is unbounded.

## Consequences

- The bash launcher carries a handshake: perl writes the group id, the tool registers it with `Helyx.Tool.register_group/1`, and only then sends the go-ahead line that lets the command exec.
- Every feature doc lists its external resources in an ownership table (`docs/features/TEMPLATE.md`); a row whose holder is a Task is a design flag the spec axis raises before implementation.
- Harness providers that spawn processes follow the same rule: they are spawned on the hands side (ADR 0003), and their processes are registered with the hands before use.
