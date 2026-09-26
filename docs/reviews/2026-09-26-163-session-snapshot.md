# Review: session snapshot (#163)

Scope: `Helyx.Session.subscribe/1` returns `Helyx.Session.Snapshot`; `Helyx.TUI.ViewModel.from_snapshot/1`; the TUI mounts from the snapshot. Feature doc: `docs/features/session-snapshot.md`.

Invariant: `subscribe/1` registers the caller in the events Registry before it asks the session for the snapshot, and the session builds the snapshot in its own process between two events. So every event with a `seq` above `snapshot.seq` reaches the client, and `ViewModel.apply/2` drops every event at or below the view model's `seq`. Boundaries: the `{:snapshot}` call of the session process (the TUI mount turns its exit into `{:session_down, reason}`), and `from_snapshot/1`, which makes the same cells and the same `call_line/1` cut as the live fold.

## Round 1 (full)

Simplify: four agents. Fixed: two call counters in `history/2` and `pair_results/1` had to stay equal; the results now come as one list in call order. Skipped: reuse of `Helyx.Session.Transcript` (a core module with `@moduledoc false`; a plugin must not call it), a single pass over the history (a result comes after its call, so one pass would have to change cells it already made), a replay through `attach_result/2` (quadratic over a long history).

Bounds sensor:

```
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

Findings: standards 8, spec 3, failure path 1.

| # | Axis | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | standards, spec, failure path | The comment of the removed `CodingAgent.fetch_model/1` stayed above `start_session/1`. | Removed. |
| 2 | standards | `Snapshot.turn` is a bare map with a known shape. | Kept: the feature doc defines `turn` as a map. |
| 3 | standards | `{:snapshot}` is a one-element tuple; other calls use bare atoms. | Kept: the feature doc names `{:snapshot}`. |
| 4 | standards | The pairing rule of `Transcript.open_calls/1` is copied in the view model. | Accepted: a plugin must not call the core module. The comment names the rule it follows. |
| 5 | standards | `ViewModel.new/1` and `Session.model/1` have no caller in `lib`. | Kept: public API, used by the tests. |
| 6 | standards | The `run/1` doc of the TUI had a broken line wrap. | Reflowed. |
| 7 | standards | The test plugins in `view_model_snapshot_test.exs` are inline. | Kept: the TUI and Fake tests define plugins inline too. |
| 8 | standards | Core had no test of `snapshot.turn.running`. | Added two tests in `test/helyx/session_test.exs`: the empty snapshot of a new session, and a local turn with three calls whose snapshot lists only the running call. |
| 9 | spec | The resume test had no tool call, so it did not show history tool cells after a resume. | The test now resumes a session with a tool call and checks the live cell shapes, then the notice only with `resumed: true`. |
| 10 | spec | Two started calls with one id in an external turn: the snapshot gives the first result to the oldest open call (the session's rule), the live fold to the newest open cell (#83). | Left open in round 1; found again in round 2 and fixed there at the mechanism (round 2, finding 1). |
| 11 | failure path | After an abort, a call that never started shows a closed `aborted` cell from the snapshot, but no cell live. Reproduced; also after a failed turn. | Accepted limit (a) of the feature doc. The doc and the `from_snapshot/1` doc now name the failed turn too. |

## Round 2 (full)

The round 1 fix touched more than one code file. Simplify: clean. Bounds sensor: skipped, as in round 1 (no key).

Precommit, run next to the review, failed on Dialyzer: `MapSet.member?/2` on the opaque `MapSet` of `running/1` (`call_without_opaque`). Fixed: `running` is a plain list of ids, at most the calls of one message.

Findings: standards 0 hard, 2 judgement; spec 1; failure path 1 (the same case as the spec finding).

| # | Axis | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | spec, failure path | Round 1 finding 10, reproduced through the provider stream: an external turn that starts `read` and `bash` with the id "t" gives live `[read: two, bash: one]` and snapshot `[read: one, bash: two]`. The transcript, the file, and the replay pair "one" with `read`, so the live client is wrong. | Fixed at the mechanism: `attach_result/2` gives a result to the oldest open cell with its id, the rule of the session, of the transcript (`Transcript.open_calls/1`), and of `from_snapshot/1`. #83 still holds: a notice between the cells does not change which cell is oldest. The #83 test case "an old cell that stayed open does not take the result of a new call" now expects the oldest cell; the session cannot leave a started cell open, because every started call gets a result, also on an abort or a failed turn. Tests: a fold unit test, and a snapshot test of an external turn with two calls of one id. `docs/features/coding-agent.md` states the rule. |
| 2 | standards | The core snapshot test used `spawn_monitor/1` but dropped the ref. | Now `spawn/1`, with a comment on why a second client subscribes. |
| 3 | standards | The accepted limits in the `from_snapshot/1` doc repeat the feature doc. | Kept: the doc cites the feature doc, and a reader needs the limits at the function. |

Round 3 is full: the fix changes 23 lines of `view_model.ex`, and it changes the rule of a mechanism that round 1 already named.

## Round 3 (full)

Simplify: clean. Bounds sensor: skipped (no key). Precommit on the round 2 fix: passed.

Findings: standards 0 hard, 2 judgement; spec 0; failure path 1.

| # | Axis | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | failure path | The oldest-cell rule spread accepted limit (b) into later turns. A local turn with two calls of the id "t" and a late client: the extra open cell of the snapshot is the oldest open cell with "t", so the result of a later call "t" went on it, and that call stayed open for ever. Reproduced through a real session. | Second finding on one mechanism (the id match of open cells), so the mechanism is fixed. The started calls are always the first calls with no result, in call order (a local turn runs its calls one at a time; an external turn starts them all). `from_snapshot/1` now gives open cells to the first `length(turn.running)` of them, by position, not by id. Limit (b) no longer applies, and the feature doc says so. Test: a local turn with two calls of one id, a late client, then a later turn with a third call of that id; it fails on the id rule and passes now. |
| 2 | standards | Row 10 of round 1 still said "open". | Already updated in the worktree before the round; the reviewer read an older diff. |
| 3 | standards | The new fold test repeats the changed #83 case. | Kept: one records #83, the other #163. |

Round 4 is full: the fix changes 48 lines of `view_model.ex`, and it is the second finding on one mechanism.

## Round 4 (full)

Simplify: clean (the view model now uses only the length of `turn.running`; the list of ids is the owner's snapshot field). Bounds sensor: skipped (no key).

Findings: standards 0 hard, 3 judgement; spec 0; failure path 0. The spec agent checked the position claim against every state of the server (local turn with calls and rejected calls, external turn with several messages, steer, abort in progress, failed turn, resume). The failure-path agent ran the round 3 reproduction and three probes with one call id everywhere (a rejected call between two others, an abort during the first call, a steer), each followed by a later turn; all held.

| # | Axis | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | standards | The `from_snapshot/1` doc and the feature doc still said an open cell is made for a call "in `turn.running`", which reads as a match by id. | Both now say: the first `length(turn.running)` calls with no result, by position. |
| 2 | standards | The removed limit (b) was still listed under the accepted limits. | Deleted from the feature doc; its history is in round 3 of this record. |
| 3 | standards | The counter `started` in `history/2` and `tool_cells/3` reads like a boolean or a list. | Renamed to `open_left`. `started/1` keeps its name: it counts the started calls. |

Round 5 is full: the fix changes 30 lines of `view_model.ex`.

## Round 5 (full)

Simplify: clean. Bounds sensor: skipped (no key).

Findings: standards 0 hard, 1 optional; spec 0; failure path 0. The spec agent checked all five acceptance criteria against the whole change. The failure-path agent ran the six snapshot tests with no warnings.

| # | Axis | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | standards (optional) | The `history/2` parameter `started` has the same name as the function `started/1`. | Kept: the parameter holds the value of `started/1`. |
| 2 | spec (nit) | Rows of rounds 1 and 3 cite limit (b), which the feature doc no longer lists. | Kept: the rows are history, and row 2 of round 4 records the deletion. |

Round 5 was clean, and the change was committed. Then the owner narrowed the rule again: the partial reply of a failed turn is display-only, and a snapshot does not rebuild it. The change adds that statement to the feature doc and to the `from_snapshot/1` doc, and two tests: a join after a failed turn with a partial reply, and a join after an abort during a partial reply. `abort_turn` closes a partial reply the same way as `fail_turn`, so the statement covers the aborted partial reply too. Round 6 is full: the change is 55 lines of tests and docs.

## Round 6 (full)

Simplify: clean. Bounds sensor: skipped (no key).

Findings: standards 0 hard, 2 judgement; spec 0; failure path 0. The failure-path agent ran the file 20 times with random seeds, with no failure, and checked every caller of `close_partial_message`.

| # | Axis | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | standards | `display_only?/1` removes aborted and failed assistant messages in every comparison, also in the older tests. | Kept; the comment now says that a snapshot never holds such a message and that `assert_joins_after_end/3` checks it with `[_user]`. Only `close_partial_message` makes such a message (the provider stop reasons are a closed set), so the older tests are not weaker. |
| 2 | standards | The feature doc sentence on the aborted partial reply used "the same holds for it". | Rewritten as two direct sentences. |
| 3 | failure path (note) | `fold(joined, events) == joined` passes by the seq guard of `apply/2`. | Kept: it is the check the owner asked for, that no event with `seq <= snapshot.seq` changes the view model. |

Codex round 2 on the rebased branch (head `00472ff`) found one more difference: an external turn that ends with `:done` while its last message has calls gives those calls `aborted` results (`end_turn/2` calls `abort_open_calls/1`), and no `tool_execution_start` comes for them. The snapshot shows a closed cell for each; the live fold shows none. Owner decision: widen the accepted limit to every call that never started and got an `aborted` result, and add no code to hide the cell; a later ADR (an item model with ids that the session assigns) removes the class. The change widens the limit in the feature doc and in the `from_snapshot/1` doc, and adds a regression test. Round 7 is reduced (spec and failure path): the change is 30 lines of tests and docs.

## Round 7 (reduced: spec, failure path)

Findings: spec 0 (1 optional); failure path 0 (1 optional). The failure-path agent ran the file 20 times with random seeds, with no failure, checked every path that records a result, and found no further drift: the extra cell is closed, so no later result attaches to it.

| # | Axis | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | spec (optional) | The `attach_result/2` comment gave only an abort as the example of a result with no open cell. | Widened to "an `aborted` result for a call that never started". |
| 2 | failure path (optional) | "After a failed turn" names a case that cannot occur today: a failed local turn has no calls that did not start, and a failed external turn closes only started calls. | Kept: the owner decision names it, and the statement stays true. The report names it. |

The review is clean.
