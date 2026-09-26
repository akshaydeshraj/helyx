# Review: no transcript copy on the session supervisor (#103, #105)

Base: `origin/master` at `bf1c552`. Rounds 1 to 3 reviewed mechanisms that the owner then replaced. Round 4 is the complete round for the final mechanism. Round 5 is a reduced round for a test fix, and that fix was then removed.

## Change

The session supervisor of Core starts with `hibernate_after: 0` (`lib/helyx/core.ex`). After each message, it hibernates, and the hibernation is a full garbage collection. `Session.start_child/2` is the same as on master.

Invariant: after a start message from `Helyx.Session.start` or `Helyx.Session.resume` reaches the session supervisor, the supervisor keeps no copy of the start state (the transcript). This is true when the start succeeds, when it fails, and when the caller dies during the start.

The doc fix of #105 is in the same change. `docs/features/coding-agent.md` now says that no client API reads the restored transcript, that the TUI starts empty after a resume, that the model keeps the context, and that #163 adds the history.

Decisions:

- The owner first decided on an explicit `:erlang.garbage_collect/1` on the supervisor after a successful start. Rounds 1 and 2 showed that a collection in the caller misses a failed start and a caller that dies during the start. Round 3 moved the start call and the collection into an unlinked Task, but the Task copied the whole state once more on every start. The owner then decided on `hibernate_after: 0` with no explicit collection. The decision is on the ticket.
- The hibernation costs one full collection for each message to the supervisor. The feature doc states the measured cost: with 20,000 children, a start takes about 2 ms, and less than 0.01 ms without the hibernation. Local mode runs few sessions, so this is accepted.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

The sensor gave the same line in every round.

## Round 1

Mechanism: `:erlang.garbage_collect/1` in the caller, after a successful `start_child`.

### Simplify

- Skipped: collect only after a resume, or collect asynchronously. The ticket said "for start and resume alike".
- The other three agents found nothing to change.

### Standards

No hard violations. Four judgement calls:

- Fixed: the test used a capture with `&2` before `&1`. It now uses `fn`.
- Fixed: the code comment and the doc now use the same words for the idle supervisor.
- Not changed: the #105 doc fix is in this change because the owner put it in this ticket.
- Not changed: the name `sup`.

### Spec

No missing requirement. One doc precision point, fixed in round 2.

### Failure path

- Fixed: a failed start (`{:error, {:already_started, pid}}` from a second resume of the same file) left 14.7 MB on the supervisor, because the collection ran only on success. The collection then ran on both branches.

## Round 2

Reduced round: one code file and about 8 lines.

### Spec

No finding. Doc nit: a start that fails before the supervisor call sends no message. The doc text was corrected.

### Failure path

- Fixed in round 3: a caller that dies while its start message waits in the supervisor mailbox never runs the collection. The probe suspended the supervisor, killed the caller, and resumed the supervisor. 6.6 MB stayed. This was the second finding on one mechanism (a collection that depends on the caller), so the next round changed the mechanism.

## Round 3

Full round. Mechanism: `DynamicSupervisor.start_child/2` and the collection ran in a `Task.Supervisor.async_nolink` Task under Core's task supervisor.

### Simplify

- Open, closed by the owner decision: the Task closure copied the whole state into the Task heap, so a resume had one more transient transcript copy, up to the 1 GiB decode cap.
- Fixed in round 4: the two tests duplicated their setup and their poll loops.
- Reuse and altitude: no change.

The worker stopped and reported three options. The owner chose `hibernate_after: 0` without an explicit collection. Round 3 had no step 2.

## Round 4

Full round: a new mechanism.

### Simplify

- Fixed: `await_free/3` and the new poll loop were the same loop. One `await/3` now serves both.
- Skipped: build the fixture with one `File.write!/2`. The tests run async, and a hand-written file must copy the id and parent format of the writer.
- Simplification and altitude: clean.

### Standards

No hard violations. Four judgement calls, not changed:

- `eventually/2` in the TUI tests is the same loop. It is in a different Mix project, and no shared test support exists.
- The memory `await` call appears three times.
- The name `memory/1` and its `elem(1)`.
- One test covers a start and a failed start.

### Spec

No finding. Without `hibernate_after: 0`, both tests fail. With the round-1 mechanism, both tests also fail. Note: the tests use only `Session.resume`, because the state of a new session is too small to measure. The hibernation works on every message.

Fixed in round 5: if the mailbox wait in the caller test fails before `:erlang.resume_process/1`, the teardown might wait on a suspended supervisor.

### Failure path

No path breaks the invariant. The agent checked a supervisor that is never idle (normal collections free the copy), a message that arrives during hibernation, the stored spec of a temporary child (no arguments are kept), a failed start, and a dead caller.

- Fixed: the cost of the hibernation was not stated. The feature doc now states it.

## Round 5

Reduced round: the test fix was 4 lines in a test file, and one doc sentence changed.

### Spec

Clean. The doc numbers match a new measurement (0.18 to 2.67 ms for each start with 20,000 children). Two STE nits in the doc sentence were fixed.

### Failure path

- Fixed: the `try`/`after` of round 5 repaired a hang that cannot happen. The VM clears every suspend that a process holds when that process exits. The probe without `try`/`after` failed in 0.5 s, with no stall. The `try`/`after` was removed, so the test is again the round-4 code.

No path broke the invariant. A start that fails in `Server.init/1` was not tested, because no boundary makes `init` fail.

After round 5, the code is the same as the round-4 code. Only Markdown changed after round 5, so no further round is needed.

## Orchestrator

- The worker stopped after round 3 with a design choice: the explicit collection that the ticket named misses a caller that dies during the start, and a Task that closes that gap adds one transcript copy per start. The owner chose `hibernate_after: 0` only. The decision is on #103.
- Rebased on #131 with no conflict. Precommit passed after the rebase.
- Codex adversarial review, round 1: no finding.
