# Review: group the interface and data shape files in folders (#117)

Date: 2026-09-26. Base: `origin/master` at `a5adc0b`. One round, the first round, complete.

The change moves 9 files of `lib/helyx/` to `lib/helyx/interfaces/` and `lib/helyx/data/`, and their 3 test files to `test/helyx/interfaces/` and `test/helyx/data/`, with `git mv`. No code line changes. It adds one rule to `AGENTS.md` and updates two paths in `docs/features/tool-text-out-of-core.md`.

Invariant: each moved file keeps its content and its module name; only its path changes.

## Step 1: simplify

Four agents (reuse, simplification, efficiency, altitude). No findings. `elixirc_paths`, `.credo.exs`, and `mix helyx.graph` use directory globs, so the new folders need no config change.

## Step 2: review

Bounds sensor output:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

| Axis | Findings | Resolution |
| --- | --- | --- |
| Standards | 0 hard, 2 judgement calls | Not changed. See below. |
| Spec | 0 | None needed. |
| Failure path | 1 | Not changed. See below. |

### Standards, judgement calls

1. The new rule could sit nearer the top of "Module naming". Not changed: it sits next to the other rule about paths ("The module path is a reading aid only").
2. `lib/helyx/interfaces/interface.ex` repeats the folder name. Not changed: the ticket names this path, and the new rule says the folder is not part of the module name.

### Failure path

1. `docs/reviews/2026-09-26-core-cleanup-plan.md:44` still names `lib/helyx/tool.ex`, and line 207 of the plan says the ticket updates "for example `lib/helyx/tool.ex` in this plan". Not changed: the ticket acceptance criteria say "Devlogs and reviews are dated records and keep the old paths", and the plan is in `docs/reviews/`. The ticket wins over the plan. The conflict is reported for a person to decide.

No code changed in step 2, so no rerun round.

## Orchestrator

- Failure path 1: rejected. The ticket's acceptance criteria rule over the plan's example: the plan is a dated record in `docs/reviews/` and keeps the old path.
- Codex adversarial review, round 1: approve, 0 findings.
