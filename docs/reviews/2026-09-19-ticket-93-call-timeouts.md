# Review: ticket #93, client calls during a sweep of the hands

Date: 2026-09-19. Branch `ticket/93-call-timeouts`. Base `25e2b51` (`origin/master`). The change was not committed during the review, so the reviewers read `git diff HEAD` from a patch file.

## Reproduction

The defect is real. A test session ran the `register` test tool with group 4242. The `kill_cmd` seam of the hands reported the group alive, with the production `wait_ms` of 5,000. `Helyx.Session.abort/1` ran in a Task, and the six client calls ran at the same time. The sweep took 5,500 ms (500 ms of TERM grace and one KILL wait).

| Call | Before the fix | After the fix |
|---|---|---|
| `queue_count/1` | exit `:timeout` after 5,002 ms | 0 ms |
| `model/1` | exit `:timeout` after 5,002 ms | 0 ms |
| `set_model/2` | exit `:timeout` after 5,002 ms | 0 ms |
| `steer/2` | exit `:timeout` after 5,002 ms | 0 ms, `:ok` |
| `follow_up/2` | exit `:timeout` after 5,002 ms | 0 ms, `:ok` |
| `prompt/2` | exit `:timeout` after 5,002 ms | 0 ms, `:ok` |
| `abort/1` | `:ok` after 5,500 ms | `:ok` after 5,534 ms |

The cause: the session waited in `Helyx.Hands.cancel/2`, a call with `:infinity`, so every client call waited behind the abort. The TUI calls `abort/1` from a Task, so the TUI itself could make a client call in that time, and the timeout stopped it. A call that timed out was still handled later, so a steer could arrive after its caller had exited.

The sweep of a delivered call never blocked the session, before or after the fix: the session waits for the tool result as a message. During a deliver sweep of 5 s the calls returned in 0 to 1 ms.

## The change

The session sends the cancel request with `Helyx.Hands.request_cancel/2` (`:gen_server.send_request/2`) and does not wait. It ends the turn and sends the abort events at once. The state field `aborting` holds the request and the abort callers. The answer of the hands arrives as a message, `Helyx.Hands.cancel_response/2` reads it, and the callers get `:ok` then. While `aborting` is set, a prompt, a steer, or a follow-up queues, and one turn starts with the queue after the answer. There is no new process, no change to a behaviour callback, and no change to the event set. The code change is 81 lines added and 12 removed in `lib/helyx/session.ex` and `lib/helyx/hands.ex`, comments and docs included.

Invariant: the session process never waits for a sweep of the hands. Thus `prompt/2`, `steer/2`, `follow_up/2`, `queue_count/1`, `model/1`, and `set_model/2` answer inside their timeout of 5,000 ms during a sweep, and `Helyx.Hands.run/3` reaches only idle hands, because no turn starts while `aborting` is set. When an `abort/1` returns, nothing that was sent before it runs or waits in a queue. Documented exceptions: `abort/1` itself waits for the sweep, with `:infinity`, by design. The list of held abort callers has no cap, one entry for each blocked caller. Each `kill` run of the hands is a `System.cmd` with no timeout (accepted in the bounds table before this ticket). `Helyx.Hands.tools/1` at session start and `run/3` keep the default timeout of 5,000 ms, and no known path reaches it.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (full, first round)

Simplify, 4 agents.

- Reuse: 3 test findings, not applied then: two copied test helpers and `timed/1`. The move of the tests in the review removed the copy of `collect_until/2`.
- Simplification: 1 applied, a comment sentence that said the same thing twice. The `if` for the queue key was not applied here and was applied in the review.
- Efficiency: clean. The new last `handle_info` clause matches only while `aborting` is set.
- Altitude: clean. The note: the statement "`run/3` reaches idle hands" is an invariant that the session holds, not the hands. A sweep in a Task inside the hands would remove it, and it needs a new process, which is out of the scope of this ticket.

Review:

- Standards: 1 probable violation, applied: the new test file did not mirror `lib/`, so the tests moved into `test/helyx/session_test.exs`. 1 smell applied: the `if` on the operation became two function clauses. 1 cosmetic doc fix applied. Long sentences in the new doc text were split. Not applied: a struct for the `{request, callers}` pair, and the `:sys.replace_state/2` in the tests, which sets the two test seams of the hands without a new option on the session.
- Spec: no wrong implementation. 1 partial, applied: no test covered the sweep of a delivered call; the test now exists. 2 doc notes, applied: the list of held callers is stated as without a cap, and the row for `run/3` names the `kill` run without a timeout. Noted, no change: `prompt/2` can now return `{:error, :queue_full}`, which its `@doc` and `@spec` state.
- Failure path: 1 finding, reproduced, applied. A second abort during the sweep did not drop the queue, so a prompt sent before it started a turn after the abort returned. The clause now calls `drop_queues/1`, and a test covers it. Probes that held: the queue limit during the sweep with multibyte text (32 accepted, the next is `:queue_full`), a stale tool result, and the exit of the hands and of a provider Task during the sweep.

## Round 2 (reduced)

The fix: 9 lines added and 3 removed in `lib/helyx/session.ex`, one code file, no new function, no change of arity, return shape, or spec. Thus a reduced round: spec and failure path. Both briefs named the invariant above.

- Spec: 0 findings. The known reproduction passed, a variant with a steer and a follow-up passed, and the abort test passed with the production wait of 5,000 ms.
- Failure path: 1 finding, reproduced with `:sys.suspend/1`, not applied as a code change. The order in the mailbox was: prompt, the answer of the hands, the second abort. The answer clears `aborting` and starts the turn of the prompt, and the second abort then aborts that turn as a running turn. The reviewer read this as a break of "no message sent before an abort starts a turn". The decision: this is not a defect. When that abort returns, nothing of the prompt runs or waits. The user message stays in the transcript, which is the result of every prompt that is followed by an abort, and master gives the same result for the same three messages. The invariant sentence was too strong, and it is now "nothing that was sent before an abort runs or waits in a queue when that abort returns". The feature doc states both orders. This is the second finding on the second abort, so a second patch of the path was not an option (two-findings rule), and no mechanism change is necessary. No code changed after round 2, so no further round.

## Defects outside the ticket

- An unknown message to an idle session stops it with a `FunctionClauseError`, because `handle_info/2` of `Helyx.Session` has no last clause for all states. Master has the same behaviour. While `aborting` is set, the new clause drops such a message. Ticket #95.
