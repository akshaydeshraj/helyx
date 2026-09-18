# Every resource has a release path that works when its owner dies

Ticket #4 took six review rounds on PR #22 (`docs/reviews/2026-09-17-abort-cleanup.md`). The internal three-axis review found nothing; Greptile, Codex, and a human review then found five more windows of one weakness: the process group id lived only inside the tool Task. A Task dies with its state, so every path that killed the Task before delivery took the only reference to the group with it, and each patch left a sibling window open.

## Decision

Every resource has a release path that works when its owner dies. A holder alone is not enough: ticket #37 showed that any cleanup that lives in a BEAM process fails when that process dies first, so the death itself must cause the cleanup. Inside the VM, work is linked to its owner, and the owner traps exits so a crash below it stays a message; the chain is session, hands, Task. At the OS boundary, a command's life is tied to its port: the perl watchdog kills the command's process group when the port closes, which any death above it causes, down to a `kill -9` of the whole VM.

A process group, port, file handle, or other OS resource that a tool creates is still registered with the hands before the external work starts, because delivery and `cancel/2` wait until the resource is gone, and that wait needs the id. If registration cannot complete, the external work does not start: either the hands hold the resource before the work runs, or the work never ran.

## Considered options

- Keep the resource in the tool Task and patch each window as a review finds it. Rejected: ticket #4 shows the windows are found one review at a time, and the class is unbounded.

## Consequences

- The bash launcher carries a handshake: the perl watchdog writes the group id, the tool registers it with `Helyx.Tool.register_group/1`, and only then sends the go-ahead line that lets the command exec.
- Every feature doc lists its external resources in an ownership table (`docs/features/TEMPLATE.md`); a row whose release path dies with its owner is a design flag the spec axis raises before implementation.
- Harness providers that spawn processes follow the same rule: they are spawned on the hands side (ADR 0003), and their processes are registered with the hands before use.
- perl is required for the bash tool; a system without it is a clear error when the hands start.

## Revision

2026-09-18, ticket #37. The original decision, "OS resources are owned by long-lived processes, never by Tasks", was too broad: a long-lived holder still fails when the holder itself dies first. The rule is restated as above, and links plus the port watchdog replaced the port scan, the perl-less launcher mode, and the kill of late registrations.
