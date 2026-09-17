# Abort with full cleanup

Ticket #4. Abort a running turn and be sure nothing it started survives.

## What was done

- `Helyx.Session.abort/1`: kills the turn Task, calls `Helyx.Hands.cancel/2`,
  gives every unanswered tool call an `aborted` error result in the
  transcript, closes a partial assistant message with an `:aborted` stop
  reason, and emits `agent_end` with `stop_reason: :aborted`. The call is
  synchronous, so a prompt sent right after abort queues behind the cleanup.
- `Helyx.Hands.cancel/2`: collects the process-group leaders from the ports
  the turn's tool Tasks opened, kills the Tasks, sends SIGTERM to each group,
  escalates to SIGKILL after a 500ms grace period, and replies only when the
  groups are empty (with a 5s ceiling for unkillable processes).
- The stale-message drop clauses in the session now also cover results from
  aborted turns; a test injects a late result and shows it never surfaces.
- Tests: two session tests (abort during tools with late-result injection,
  abort during a hanging stream), a no-turn no-op test, and two bash plugin
  tests that verify the OS process and its child are gone the moment abort
  returns, including a TERM-ignoring command that needs the KILL escalation.

## What broke

- The scripted "abort" model first matched on the last transcript message
  being a tool result, which is false after a fresh prompt follows an abort;
  it now checks for any tool result in the transcript.

## Follow-up: PR #22 review

A PR reviewer found a real merge blocker: a background child left by a
completed call in the turn survived the abort, because the hands only scan
live Tasks. First fixed in the bash tool: the command's process group is
killed when the call completes. While reviewing the fix we measured that
port programs lead their own process group even without perl, which
shrinks the perl-less ceiling to stdin handling only.

Further reviews hit the same weakness (a `Port.info/2` nil race, then
aborts that land around the port's close), so group ownership moved to the
hands and the launcher gained a handshake: the tool registers its group
with `Helyx.Tool.register_group/1` before it sends perl the go-ahead line
that lets the command exec, and the hands kill the group on delivery,
holding the result until the group is gone, and on cancel. Either the
hands hold the group before the command runs, or the command never ran.
See the follow-up sections of `docs/reviews/2026-09-17-abort-cleanup.md`.

## What is next

- Hands-owned spawning would close the remaining perl-less gaps (no
  handshake, stdin stays the port pipe); it fits naturally in the harness
  provider tickets.
- Steer (abort plus a new prompt in one step) builds on this per the feature
  doc.
