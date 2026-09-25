# Design review: tool resource release

Three review rounds on the design of `docs/features/tool-resource-release.md`, 2026-09-25, before implementation. The proposal came from an architecture review of Core: the OS process code in `Helyx.Hands` is used only by the bash tool.

## Round 1, on revision 1

Revision 1 removed the hands registry. The tool Task was to trap exits and wait for its watchdog, and the hands were to cancel with `Task.shutdown/2`. The rule that refuses later calls while a group survives KILL was to be dropped.

| Finding | Resolution |
| ------- | ---------- |
| Closing the port does not confirm that the OS process exited. | Revision 3: no new port protocol. The release polls until the groups are gone, as today. |
| KILL is not confirmation. A Task can die while the hands live, and the next call can overlap the cleanup. | Revision 3: the hands release on every Task end and poll, as today. |
| Keep protection against unresolved cleanup. | Kept: the unconfirmed set and the refusal. |
| A Task that traps exits needs an owner-death path. | No `trap_exit` is added. |
| Keep the behaviour tests. Registration is in the Decision of ADR 0004, not only in its Consequences. | Tests kept with a delaying test tool. The Decision is amended. |

## Round 2, on revision 2

Revision 2 kept the refusal rule. It added a cancel line on the watchdog's stdin, a confirmation through the exit status, and an `after` block in the tool Task.

| Finding | Resolution |
| ------- | ---------- |
| Track the watchdog as well as the command group. | Both are held, as `{:watchdog, pid}` and `{:command, group}`, at today's two stages. |
| The unconfirmed rule must cover every unexpected Task death; `after` does not run for every exit. | No `after`. The hands release on every reply or `:DOWN`. |
| Command status and cleanup status must be separate; the watchdog must reap its child before the group poll ends. | The exit status keeps today's meaning. Cleanup status is the return value of `release/3`. The watchdog is still released last. |
| Bound the callbacks; a failure is unconfirmed; one total deadline, longer than the inner waits. | Bounded release Task; 20 s over a worst inner sweep of 15.5 s. |
| Define how a handle becomes released. | Only by the return value of `release/3`. |
| Remove the unmeasured timings and the claim that `node_modules` stays consistent. | Removed. |

Each round found new gaps in the changed protocol. ADR 0004 records the same pattern from ticket #4. Revision 3 changed the strategy: move the OS code, do not change the protocol.

## Round 3, on revision 3

The reviewer approved the scope, with requirements.

| Requirement | Resolution |
| ----------- | ---------- |
| Stop a release Task before another attempt; ignore late replies. | `Task.shutdown(:brutal_kill)` at the deadline; a reference on each request. |
| An unconfirmed cleanup turns the result into an error. | In the contract and in the hands rules. |
| Absolute monotonic deadline; one retry budget for all modules. | In the interface and the bounds table. |
| `release/3` is safe to call again; strict check of the return value; a failure keeps the handles. | In the interface and the hands rules. |
| "Without changing any behaviour" is too strong. | Replaced with "preserve the existing cleanup and refusal contract". |
| `Helyx.Tool.Bash` implements the callback and delegates to `Helyx.Tool.Bash.Group`. | In the interface section. |

Agreed decisions: one `release/3` callback with three modes; 20 s for `:deliver` and `:cancel`, 1 s for `:retry`; `Helyx.Tool.Bash.Group` as an internal module.

## Implementation review, round 1

`/ship` on the working tree against `origin/master` (`efd5d9f`).

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify, applied: `Enum.find_value` over the task map in the `hold` handler; one `Map.split` of the held handles in `cancel`; one clause each for `retry/1` and `release/4`; the retry deadline is the attribute `@retry_ms`; `left -- handles` for the return check; `Enum.flat_map` in the error text; `defdelegate` for `Bash.release/3`; one `sweep` clause for `:deliver` and `:cancel`; test names in the preamble test. Skipped: an asynchronous release in the hands (a behaviour change, out of scope); one `kill` run per poll for all groups (moved code, unchanged); `Task.Supervisor.async_stream_nolink` (the zip stays short); the two transcript-safe handle forms of the test tool (the "stuck" call goes into the transcript).

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | No tests at the limits of the deadlines. | Added: a release 50 ms under and 50 ms over the deadline, and a retry that passes its 1,000 ms deadline. |
| Spec | A reply that arrives before the kill at the deadline counts as returned. | Kept: the release did return. Rule 4 and a comment in the hands now say so. |
| Spec | `poll_gone` could sleep up to 20 ms past the deadline. | The sleep is at most the time that is left. Test: no wait passes the deadline. |
| Spec | `Group.release/4` dropped a handle it did not know, so the hands saw it as released. | An unknown handle, or a group below 2, is returned as still held and never signalled. |
| Standards | The feature doc named `Task.shutdown` where the code uses `Task.yield_many` with `:kill_task`. | Rule 4 names both. |
| Standards | Long sentences in the moduledocs, "sweep" and "registered" where the terms are now "release" and "hold". | Rewritten in the hands, session, and tool docs and in ADR 0003 and 0004. |
| Standards | `merge/2` did not say what it merges. | Renamed `add_handles/2`. |
| Standards | `group_alive?` in the group test repeated a helper. | Uses `group_gone_within?` of the bundled test helper. |
| Standards | The task entry is a four-element tuple, matched by position in six places. | Kept: the shape is internal to the hands and the tuple grew by one field. A struct is a separate change. |
| Standards | `hold/1` raises for a tool without `release/3`. | Kept: rule 7 of the agreed design. |
| Failure path | None reproduced. Cancel and Task kill at 24 points, a suspend between the two holds, and a stuck zombie all left no process. | – |

Round 2 is a full round: the fix changes 51 code lines in four code files and adds `valid?/1`.

## Implementation review, round 2

A full round. Simplify: `valid?/1` puts its whole check in one guard. Skipped: a shape check at the `hold/1` call in the bash tool in place of `valid?/1` (the bash tool holds only the two valid forms, and the release must still not confirm an unknown handle), and one `kill -0` run for all groups (the per-group probe is what tells which group is gone).

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path, spec | `alive/2` counted any failed `kill -0` as gone. `EPERM`, for a group of root processes, confirmed a live group as released. | A group is gone only when `kill` reports "No such process". `kill` runs with `LC_ALL=C`. Test: a probe that fails with another error keeps the group held. |
| Failure path | The `kill` runs were not bound by the deadline. With slow `kill` runs, `:cancel` passed a 50 ms deadline by 172 ms, and `:retry` did not look at the deadline. | Second finding on the deadline of the bash release, so the mechanism is fixed: every `kill` run goes through one gate, and no run starts at or after the deadline. A skipped probe keeps the group held. Test: a release with a passed deadline runs no `kill` and returns every handle. |
| Spec | No test at the 500 ms grace and the 5,000 ms wait. | Added both. The watchdog test uses the real 20,000 ms deadline, because its KILL comes after one full wait. |
| Spec | `coding-agent.md` said a group is returned as held after the ceiling, but the deadline can come first. | The row names both cases. |
| Standards | "sweep" and "registered" in the hands, session, feature docs, and the review checklist; "held" for the result; three names for one idea in the hands. | Replaced with "release" and "hold"; the error helper is `unconfirmed_error/1`. "Sweep" stays inside the bash plugin, where it names the sequence of signals. |

Round 3 is a full round: the second finding on the deadline mechanism, and the fix touches four code files.

## Implementation review, round 3

A full round. Simplify: the deadline test drains the probes too (`refute_received`), the match on "No such process" is `String.contains?/2`, and one of two comments on the gate is removed. Skipped: a perl probe that reads `ESRCH` and probes every group in one run (a new probe seam and a larger change; the text match with `LC_ALL=C` is tested), and the merge of two deadline tests (they cover `:deliver` and `:cancel`).

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | A command can move a child out of its group (`set -m`, `setsid`, `setpgrp`). The command group is gone, so the release confirms every handle, and the child lives on. | The known limit of process groups, the same as before this change. `coding-agent.md` names the three ways, and the ownership table of the feature doc has a row for it. |
| Spec | The gate test used a deadline that had already passed, so a check only at entry would pass it. | Added a test with a slow `kill` that crosses the deadline during a `:cancel`. |
| Spec | `coding-agent.md` said "after" the deadline where the code and the feature doc say "at or after". | Fixed. |
| Standards | "abort sweep" in `coding-agent.md`. | "the release of an abort". |
| Standards | The name `before/2` did not say what it does. | Renamed `until_deadline/2`. |

Round 4 is a reduced round: the code fix is a rename of 2 lines in one code file, and it adds or removes no function.

## Implementation review, round 4

A reduced round: spec and failure path. No findings. A copy with the gate checked only at entry fails the new test (172 ms past the deadline). Real groups in each state (running, of another user, a zombie, gone) cross the deadline and the three modes as the docs state. Not reproduced, recorded as gaps: a scheduler delay between the time check and the `kill` run, and the `:retry` KILL of a watchdog on a Linux host where PID 1 does not reap orphans (the handle stays held, never released by mistake).

Precommit: Credo found a fake `kill` nested too deep in the group test, and Dialyzer found the improper list that the `Hold` test tool returns on purpose. The probe of the fake is its own function, and `Hold.release/3` has `@dialyzer {:nowarn_function, release: 3}`. Both are test files, so no review round follows.

## Codex review, round 1

Adversarial review against `origin/master`, 2026-09-25: approve, no findings. Its probe of an abort race kept the unconfirmed handles, gave an error result, and refused the next call.
