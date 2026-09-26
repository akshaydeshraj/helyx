# Review: session_not_found and client start errors (#188)

Invariant: every contract operation of `Helyx.Session` (`subscribe/1`, `prompt/2`, `steer/2`, `follow_up/2`, `abort/1`, `set_model/2`) on a session that is not running returns `{:error, :session_not_found}` through one private `call/3`, a caller holds at most one registration for a session, every `subscribe/1` starts by dropping the queued events of the id, and a failed `subscribe/1` (`:session_not_found` or a `:timeout` exit) leaves no registration and no event of the id in the caller. `client_start_error/1` is the one mapping from a start or resume error to the closed list of ADR 0006, section 2, and a ref passes only within the bounds of `Helyx.ModelRef`. Boundaries: the exit of `GenServer.call/3` (every reason except `:timeout`), and the start error term, which includes a model ref from the session file. Accepted hole: a new instance from a concurrent resume can send one event to the caller's entry after a failed subscribe drops the events; the next subscribe drops it. Documented exception: `model/1` is not in the contract and keeps its exit.

Feature doc: `docs/features/session-not-found.md`.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (before the round): `@start_failed` inlined; the TUI mount exits with `{:session_down, :session_not_found}` on both paths. Skipped: remove `client_start_error/1` (the ticket asks for it); `start_for_client/2` wrappers (the ticket asks for one mapping function); one shared "session ended" string.

### Standards: 0 hard, 6 judgement calls

1. `model_error(:session_not_found)` in the TUI is not a model error. **Fixed**: renamed to `switch_error/1`.
2. The guard of `client_start_error/1` repeats the tags of `model_error()`. **Accepted**: no function tests "is a model error"; the test of the pass-through list fails when a tag is missing.
3. The doc said "Every transport calls it", but no transport exists. **Fixed**: "A transport calls it".
4. `timeout \\ 5_000` repeats the `GenServer.call/3` default. **Accepted**: the bounds table states it.
5. The test name "a text that is not UTF-8 is refused before the call" also covers a model error. **Fixed**: "input errors win over session_not_found".
6. The Registry partitions stay suspended when an assertion fails. **Accepted**: each test has its own Core, which `start_supervised!` stops.

### Spec: 0 missing, 4 notes

1. The "session ends during the snapshot call" test kills the session after the call is queued, not before the call is sent. **Accepted**: the window before the call gives `:noproc`, which the "dead session that is still registered" test and the "ended" test cover.
2. `mount/1` still calls `Session.pid/1` after the subscribe. **Accepted**: stated in the feature doc; ticket 2 of ADR 0006 removes it.
3. A `:timeout` exit of `subscribe/1` keeps the registration. **Accepted**: written as a hole in the feature doc.
4. A stale TUI comment named a `noproc` crash on the next key press. **Fixed**.
5. The bounds row of the log line did not say that `inspect/1` limits apply per collection. **Fixed** in the doc.

### Failure path: 2 findings, both reproduced

1. `client_start_error/1` passed `{:invalid_model_ref, ref}` unchanged. On resume the ref comes from the session file, so a client got a 1,000,024-byte ref. **Fixed**: the ref passes only as valid UTF-8 of at most 256 bytes (`Helyx.ModelRef.max_bytes/0`); any other ref becomes `{:start_failed, text}` and goes to the log. Tests at 256 bytes, at 257, at 128 two-byte characters (256 bytes), one byte over with a multibyte ref, and a byte that is not UTF-8.
2. A failed `subscribe/1` left in the caller's mailbox the events that the session sent to the new registration before it died. A client that subscribes after a resume with the same id could apply them as live. **Fixed**: with no other registration of the caller for the id, the failed subscribe flushes the events of the id. The test queues a prompt, a stop, and the snapshot call on a suspended session; it failed without the flush and passes with it.

Fix size: 42 added and 14 removed code lines in 3 files, with new functions, so round 2 is a full round.

## Round 2 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree before the round 1 fixes.

Simplify: no change applied. Two points were taken into the round 2 fix below (one ref rule in `Helyx.ModelRef`; control characters). Skipped: a shared constant for the `:start_failed` text in the tests; a separate commit for the `switch_error/1` rename. Skipped: bound the ref inside `ModelRef.parse/1`, because that changes the error of `parse/1` for every caller; the client mapping is the boundary to a client.

### Standards: 0 hard, 6 judgement calls

1. The ref check in `Helyx.Session` repeated part of the rule of `ModelRef.parse/1`. **Fixed**: `Helyx.ModelRef.bounded?/1` holds the rule, `parse/1` and `client_start_error/1` both call it, and `max_bytes/0` is gone.
2. A ref with a control character from the session file passed to a client. **Fixed** with item 1: `bounded?/1` refuses whitespace and category C characters. Tests: `"a b"`, `"a/\e[2J"`, `"a/b\n"`.
3. The `@doc` of `subscribe/1` did not state the mailbox flush. **Fixed**.
4. The flush loop has no deadline. **No finding**: the dead session sends no new event.
5. The `:start_failed` text is in three places. **Accepted**: the tests assert the exact value.
6. The tests hard-code 256. **Accepted**: the test names the bound of `Helyx.ModelRef`.

### Spec: 1 finding

1. The events Registry has duplicate keys and sends one event for each entry. A caller that subscribed before and then failed a second subscribe kept one copy of each event from the failed entry, because the flush ran only with no other entry. **Fixed** (see below).

### Failure path: 1 finding, reproduced

1. The same path as the spec finding: seqs `[1, 1, 2, 2, 3, 3, 4, 4]` stayed in the mailbox. This is the second finding on the flush mechanism, so the fix changes the mechanism: a caller holds at most one registration for a session (a second subscribe does not register again), and a failed subscribe removes the caller's registration and every event of the id. The test subscribes twice, checks one entry, makes the session emit and stop before the snapshot call, and checks that no event and no entry stays. It also removes the double delivery after a second successful subscribe, which existed on master.

Invariant 1 held under every probe of round 2.

Fix size: 28 added and 23 removed code lines in 2 files, with a new function and a removed one, and the two-findings rule applies, so round 3 is a full round.

## Round 3 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree before the round 2 fix.

Simplify: the new test copied the suspend harness of the older flush test. **Fixed**: merged into one test. The comment at the register check now says why the check and the register do not race.

### Standards: 0 hard, 5 judgement calls

1. `bounded?/1` checks more than size. **Accepted**: the module doc of `Helyx.ModelRef` calls all these rules its bounds.
2. The `@doc` of `client_start_error/1` said the rule twice. **Fixed**.
3. `Registry.values(...) == [nil]` names the stored value. **Accepted**: the value is part of what the test pins.
4. The merged test lost the comment on the suspend harness. **Fixed**: restored.
5. No other smell.

### Spec: 1 finding, 1 read-only note

1. A caller that subscribed, did not read its events, and subscribed again after a resume kept the events of the old instance. The resumed session starts at `seq` 0, so the client applied them as live (probe: snapshot `seq` 0, then old events 1..9). **Fixed** (see below).
2. A concurrent resume can send an event to the caller's entry after a failed subscribe drops the events. Not reproduced. **Accepted** as a hole in the feature doc: the next subscribe drops it.

### Failure path: 1 finding, reproduced

1. A subscribe that exits on `:timeout` kept its entry, and a caller that caught the exit then got 9 events with no snapshot. Round 1 had written this as an accepted hole. **Fixed** (see below).

Both findings are on the same mechanism as the round 1 and round 2 findings: the state of the caller for a session around `subscribe/1`. So the fix is a rule for all paths, not a patch for the path: every subscribe drops the queued events of the id before it registers, and every failed subscribe, `:session_not_found` or an exit of the snapshot call, removes the entry and drops the events again (`leave/2`). Tests: a re-subscribe after a resume with unread events of the old instance; a subscribe to a suspended session that times out. Both failed without the fix and pass with it.

Fix size: 23 added and 10 removed code lines in 1 file, with a new function (`leave/2`), and the two-findings rule applies, so round 4 is a full round.

## Round 4 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Base: the tree before the round 3 fix.

Simplify:
- The timeout test left the session suspended when an assertion failed. **Fixed**: it resumes before it asserts.
- `leave/2` looks up the registry again. **Skipped**: the `catch` clause has no `registry` in scope.
- The test helper for `Registry.values/3`. **Skipped**: three short lines.
- The timeout test waits 5 s. **Accepted**: `subscribe/1` has no timeout argument, and the module is async.
- Altitude: the root cause of old-instance events is that a resume starts `seq` at 0 and an event has no instance id. The mailbox drop reaches only a local client. **Not decided**: an interface change of `Helyx.Event` and the snapshot, out of scope of #188 and written in the feature doc for the owner.

### Standards: 0 hard, 5 judgement calls

1. The registry lookup repeats in `leave/2`. **Accepted**: the `catch` clause has no `registry` in scope.
2. The general `catch :exit` in `subscribe/1` sees only `:timeout`, and `exit(reason)` drops the stacktrace. Open.
3. The name `leave/2` does not say that it drops events. Open.
4. The resume test waits for any message, not for an event. Open.
5. The timeout test does not check the mailbox drop, or a caller with an earlier entry. Open.

### Spec: 3 findings, open

1. A successful subscribe keeps its entry into the next instance. After a resume with the same id and `seq` 0, the TUI monitors the new pid from `Session.pid/1` and `ViewModel.apply/2` drops or applies the new events against the old snapshot.
2. On `:timeout` the session is alive, and `Registry.dispatch/3` can send one event after `leave/2` drops the events. The feature doc names only a concurrent resume.
3. `flush_events/1` matches the session id only, not the Core.

### Failure path: 1 finding, reproduced, open

1. Two Cores resume one `sessions_dir`, so two sessions have the same id. A subscribe to Core B drops the unread events of the caller's live subscription to Core A (4 events to 0), and the Core A stream then has a gap in `seq`. The failure branch does the same. `lib/helyx/core.ex` says that sessions and their subscribers are scoped to their Core.

### Stopped: owner decision needed

This is the fourth round on one mechanism. Every open finding has one root cause: a `{:helyx_event, event}` message does not identify its Core or its session instance. A resume reuses the id and starts `seq` at 0, and two Cores can hold one id. Each fix needs an interface change that #188 and ADR 0006 do not state:

- an instance id (and the Core) in `Helyx.Event` and in the snapshot, so a client and `flush_events/1` match the instance;
- `seq` that continues across a resume;
- a rule that a session id is unique in the node, with a check at `resume/2`.

The change stays uncommitted until the owner decides. Also open for the owner: whether the mailbox drop of rounds 1 to 3 stays, or goes when events carry an instance id.
