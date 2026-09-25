# Ticket #100: the OS release work of process groups moves into the bash plugin

Date: 2026-09-25. Branch `ticket/100-tool-resource-release`.

## Done

- An architecture review of Core found that `Helyx.Hands` held the process groups of the bash tool and did all the OS work to release them. The design went through three review rounds (`docs/reviews/2026-09-25-tool-resource-release.md`) and became `docs/features/tool-resource-release.md`. ADR 0003 and ADR 0004 are amended.
- `Helyx.Tool.register_group/2` is now `Helyx.Tool.hold/1`, with an opaque handle. `Helyx.Tool` has the optional callback `release(handles, mode, deadline)`.
- The hands keep the handles per Task and call `release/3` in a Task per tool, in parallel, with one deadline: 20,000 ms for `:deliver` and `:cancel`, 1,000 ms for `:retry`. A timeout, a raise, an exit, or a bad return value confirms no handle. An unconfirmed handle makes the result an error, and later tool calls are refused while it is held.
- `lib/helyx/hands.ex` has no signal, no `kill`, no group kind, and no poll. That code is in `Helyx.Tool.Bash.Group`. The watchdog, the handshake, and the exit status do not change.
- The test tool `Register` is now `Hold`, with `HoldTwo` and `HoldBare`. No Core test fakes `kill(1)` or replaces the state of the hands. The tests of #93 stay.

## What broke

- Round 1: no tests at the limits of the deadlines, a sleep in the poll that passed the deadline, and an unknown handle that counted as released.
- Round 2: a `kill -0` that failed with `EPERM` counted as gone, and the `kill` runs were not bound by the deadline. The second finding on the deadline made the fix a gate around every `kill` run.
- Round 3: a command can move a child out of its group with `set -m`. This is the known `setsid` limit, now named with all three ways in the docs.

## Next

- Ticket #101: a bound on the handles per Task.
- A perl probe that reads `ESRCH` and probes all groups in one run would remove the text match on "No such process" and the `LC_ALL=C`.
- The other candidates of the architecture review: abort through the mailbox of the hands, the tool text helpers out of Core, one module for the provider stream, and a snapshot on subscribe.
