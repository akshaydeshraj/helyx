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

No code changed after round 1, so no rerun round.
