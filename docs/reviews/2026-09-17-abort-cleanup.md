# Review: abort with full cleanup (ticket #4)

Scope: the working tree change that adds `Helyx.Session.abort/1` and
`Helyx.Hands.cancel/2`. Three axes ran as parallel agents after a `/simplify`
pass whose fixes (a shared `record_result/3`, a collapsed poll loop, deduped
test scripts) were applied and re-tested before this review.

## Standards

No hard violations of `AGENTS.md`. Judgement calls:

- `alive?/1` duplicates the `kill` invocation shape of `signal/2`; a one-line
  merge is possible. **Skipped**: optional, two lines, cold path.
- The hands `tasks` value grew to a three-tuple `{task, turn_id, call_id}`.
  **Accepted**: a struct would be over-weight for a private map value.
- `cancel/2` filters by turn id although the hands hold one turn's tasks at a
  time. **Accepted**: the feature doc requires cancel-by-turn-id.

## Spec

All five acceptance criteria implemented and tested. Deviations and notes:

- The hands stop waiting 5s after SIGKILL instead of blocking forever on an
  unkillable process. **Accepted**: deliberate, marked with a `ponytail:`
  comment in `hands.ex`.
- "A prompt right after abort waits for cleanup" is guaranteed structurally
  (abort is a synchronous call that returns after `Hands.cancel/2`); the bash
  plugin test proves the reply ordering by checking the process is gone the
  moment abort returns. No separate queued-prompt test. **Accepted**.
- Race: a cancel that lands after a tool Task spawns but before its
  `Port.open` completes finds no port to signal, so that command's group is
  not killed. The window is microseconds against a human-initiated abort.
  **Accepted**: the root fix is hands-owned spawning (planned for the harness
  tickets); recorded here rather than patched around.
- Tool calls streamed into a partial assistant message that is aborted get no
  `aborted` results. **Accepted**: the partial message never joins the
  transcript, so the provider sees no dangling call; `event.ex` documents the
  message-level close.

## Failure paths

No defects reproduced. Probed with throwaway tests under `.scratch/review/`
(deleted): abort before the first stream event, abort twice, seq contiguity
across an aborted turn, cancel with no tasks, and abort racing a
same-instant tool finish for 25 iterations. Known marked ceilings: perl-less
hosts run commands in the node's process group (group kill misses them), and
an unkillable process unblocks cancel after 5s.

## Follow-up: PR #22 merge-blocking finding

A PR review found a fourth defect the axes above missed: `Hands.cancel/2`
scans only live tool Tasks, so a background child left by a **completed**
call in the same turn survived the abort. Reproduced with
`sleep 60 >/dev/null 2>&1 &` in a first call and an abort during the second.

**Fixed** in the bash tool rather than the hands: the command's process
group is SIGKILLed when the call completes, so no process survives its
call. This closes the abort case, closes the same leak in the normal flow,
and needs no per-turn group state in the hands. The altitude axis judged
the depth right: the tool creates the group, so the tool tears it down;
move to hands-tracked groups when a second spawner (harness providers, a
background shell feature) appears. Regression test: "a detached background
child does not survive the call".

Review of the fix (same three axes) confirmed it closes the exact repro
and found two low items, both fixed: a guard for `Port.info/2` returning
nil when a command exits before the pid lookup, and a wrong launcher
comment — measured on this machine, the runtime detaches port programs, so
the command leads its own process group even without perl. That voids the
earlier perl-less group-kill ceiling; the remaining perl-less gap is only
stdin (the command would read the port pipe and hold the call). Skipped as
optional: `cond` versus function clauses in a test helper, and a shared
poll skeleton between two test helpers.

A later bot re-review flagged that the nil guard skips the group kill, so
a shell that exits before the pid lookup could still leak a detached
child. First fixed with a temp-file handoff; the next re-review rightly
flagged that a predictable shared-temp path is symlink-racable and that
aborts leak the files. **Fixed** by removing the file: perl writes the
group id as the first line of stdout before it execs the command, and the
tool reads the marker off the stream. No file exists to attack or leak,
command output cannot precede the marker, and a `pgid > 1` guard keeps a
malformed value away from `kill`. The `Port.info/2` value remains only as
the perl-less best effort. Reviewed by hand per the diff-size rule.

A Codex review then found the last window of the same class: the shell
exits (the port closes) before the tool Task runs its completion kill, and
an abort in that interval brutal-kills the Task that holds the group id —
nothing left knows the group. Three findings against the same weakness
(the group id lived only inside the Task) ended the patching: **fixed**
structurally with hands-registered groups, the upgrade path the earlier
rounds had marked. The bash tool registers its group with the hands via
`Helyx.Tool.register_group/1` right after the marker read; the hands hold
it outside the Task, kill it on delivery (however the Task ended, so a
crashing tool no longer leaks either) and on cancel, alongside the port
scan that still covers a call aborted before registration. Regression test
suspends the tool Task to hold it in the exact window ("abort kills the
child of a shell that already exited"); verified to fail with registration
disabled. Reviewed by hand per the diff-size rule.

A second Codex review rightly rejected the claim that the port scan covers
the spawn-to-registration window: a scheduler-starved Task can leave the
marker unread while the shell exits and closes the port, so an abort then
loses the group with nothing to scan. **Fixed** with a stdin handshake
that removes the window instead of shrinking it: perl writes the marker,
then blocks on one stdin line before it execs the command; the tool sends
the go-ahead only after `register_group/1` returns. A Task killed before
the go-ahead closes the port, and perl exits on end-of-file without
running the command. The invariant is now structural: either the hands
hold the group before the command runs, or the command never ran.
Verified by hand that a port closed before the go-ahead leaves no process
and never runs the command. The perl-less path keeps its best-effort
ceiling.

A Greptile re-review then flagged that `deliver/3` published the result
right after the SIGKILL, so the next call could start while the killed
group was still dying, and a straggler dropped from the groups map could
no longer be awaited on abort. **Fixed**: delivery reuses the liveness
wait and holds the result until the group is gone, with the same 5s
ceiling as cancel for a process stuck in uninterruptible kernel I/O.
