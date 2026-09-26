# Review: ticket #170, the TUI `:DOWN` clause

Date: 2026-09-26. Base: `origin/master` at `11be2f6`. Scope: `plugins/bundled/lib/helyx/tui.ex`, `plugins/bundled/test/helyx/tui_test.exs`.

## Change

`Helyx.TUI.mount/1` keeps the reference and pid of the session monitor in `state.monitor`. The `:DOWN` clause of `handle_info/2` matches only that reference and pid. Any other `:DOWN` falls to the catch-all clause and is ignored.

Current trigger: the ticket names a provider `id/0` during `/model`. Since #169, `id/0` runs once at Core start. A provider `turn/0` still runs in the TUI process during `/model` (`Session.set_model/2`, then `Helyx.Provider.turn/1`). The code comment and the test provider `Helyx.TUI.Test.Provider.Monitors` state this trigger.

## Simplify

- Simplification: store the bare reference, not `{ref, pid}`. Skipped: the acceptance criteria ask for a match on the reference and the pid.
- Reuse: the `{ref, pid}` pairing repeats the idiom of `run/1`. Minor, no helper needed. No change.
- Efficiency, altitude: clean.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Standards: 0 findings. Judgement call: rename `monitor` to `session_monitor`. Skipped: the field comment states the shape and the owner.
- Spec: 0 findings. Note: the issue body still names `id/0`; the closing record states the `turn/0` trigger.
- Failure path: 0 findings. Checked the stray monitor through `/model`, a second monitor of the session pid, a session that dies between `Session.pid/1` and `Process.monitor/1` (the `:noproc` `:DOWN` carries the same reference and pid), and the monitors of ExRatatui (only in the distributed transport, handled by the runtime before the app).

No code changed after round 1.

## Codex round 1

1 finding, confirmed. The test provider's `turn/0` did `Process.monitor(spawn(fn -> :ok end))`. The child can exit before the monitor is set, so the `:DOWN` reason is `:noproc` and the test's `assert_receive ... :normal` fails (188 in 100,000 runs, measured by Codex). **Fixed**: `spawn_monitor/1`. New line in `docs/agents/review-checklist.md`, "Races and resource ownership".

## Round 2 (reduced)

Fix diff without test files and Markdown: 0 lines, 0 code files, so a reduced round (spec and failure path). Invariant: the test's setup always puts one `:DOWN` of another monitor, reason `:normal`, in the test process through the real `/model` path, and every `assert_receive` matches on every run. Base `f43eb7d`. Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Spec: 0 findings.
- Failure path: 0 findings. Reproduced the old form under concurrency (13 non-`:normal` in 1.6M runs; `spawn_monitor/1` 0). A mailbox probe through `/model` (3,000 runs) found exactly one `:normal` `:DOWN` after `/model` and two `:killed` after the kill. The test passed 2,001 of 2,001 runs with `--repeat-until-failure`.

## Orchestrator

- Codex adversarial review, round 1: 1 finding, confirmed. The test provider did `Process.monitor(spawn(...))`, which can give `:noproc`, so the test was flaky. Fixed with `spawn_monitor/1`, and a line in `docs/agents/review-checklist.md`, "Races and resource ownership".
- Codex adversarial review, round 2: no finding. The base did not change after the precommit run of the worker.
- The ticket names `id/0` as the trigger. Since #169 it is `turn/0` during `/model`; the closing comment on the ticket says so.
