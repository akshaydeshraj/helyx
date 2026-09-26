# Review: the plugin table in Registry meta (#165)

Base: `origin/master`. One complete round. No round found a defect, so no rerun was necessary.

## Change

Core keeps the resolved plugin table in the meta of its sessions Registry (`meta: [plugins: table]` in `Helyx.Core.init/1`). `Helyx.Core.plugins/2` reads it with `Registry.meta/2`. The `Helyx.Core.Plugins` Agent is removed. The module keeps `resolve/2` and its checks. The Core child list has one entry fewer.

Invariant: `Helyx.Core.plugins/2` returns the table that Core resolved at start, in registration order, and a restart of the sessions Registry keeps that table, because the child spec holds it.

Other items:

- The session test "a provider call makes no call to the plugin table (#122)" is removed. It suspended the Agent to show that a provider call does not wait on the table process. That process no longer exists. `Registry.meta/2` reads ETS and sends no message, so no lookup can wait on a process.
- The Core moduledoc and `README.md` do not list the Core children, so the criterion "where they list the Core children" requires no change.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

The four agents (reuse, simplification, efficiency, altitude) found nothing to change.

### Standards

No hard violations. Two judgement calls:

- Not changed: the sessions Registry also holds the plugin table, and its name does not say so. The ticket asks for this place. The comment on the child spec says that the spec holds the table.
- Not changed: the #122 test has no replacement. The property it guarded now holds by construction (see "Change").

### Spec

No missing criterion, no scope creep, no wrong implementation. The reviewer confirmed that the moduledoc and `README.md` list no Core children, and that the removal of the #122 test is correct.

### Failure path

No reproduced finding. Probes:

- A lookup while the sessions Registry is suspended returns at once.
- A lookup during a Registry restart raises `ArgumentError`. The Agent had the same window and exited with `:noproc`. After each of 50 restarts, the table was correct.
- `Session.start/2` on a Core that does not run raises `ArgumentError` instead of an exit with `:noproc`. No `catch :exit` in `lib`, `plugins/bundled/lib`, or `apps/*/lib` wraps a call to `Helyx.Core.plugins/2`. The Core name comes from product config, not from the model.
- Nothing calls `Registry.put_meta/3`, so no other process can replace the table.

## Orchestrator

- Codex adversarial review, round 1: no finding. The base did not change after the precommit run of the worker.
- Accepted: a lookup during a Registry restart raises `ArgumentError` in place of an exit with `:noproc`. Both crash the caller.
- Accepted: the #122 test is removed with no replacement. `Registry.meta/2` reads ETS, so a lookup cannot wait on a process.
