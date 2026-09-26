# Review: ticket #164, cleanup of unused API and duplicate code

Scope: the eight accepted items of #164 on base `b11852e`. The items the owner rejected are not changed. `plugins/bundled/lib/helyx/provider/codex.ex` is not changed.

Invariant: the change removes code and duplicate code only, and every client, plugin, and event sees the same behaviour as before.

## Items

All eight items still existed on `b11852e`. Each one is done:

1. The root `stream_data` dependency and its lock entry are removed. `plugins/bundled` keeps its own.
2. `Helyx.ModelContext.build/3` and `Helyx.Compaction.compact/3` are deleted. `none_test.exs` calls `Helyx.Compaction.None.compact/2`.
3. `Helyx.Session.queue_count/1` and the `:queue_count` handler are deleted. The tests assert on `queue_update` events.
4. `Helyx.Session.Hands.cancel/2` and `cancel_response/2` are deleted. The server calls `:gen_server.check_response/2`. The hands test has a private `cancel/2` helper that calls `:gen_server.receive_response/2`.
5. `prompt/2`, `steer/2`, and `follow_up/2` call one private `send_text/3`.
6. The hands have one `{:start, turn_id, job}` clause for a tool call and a harness stream. `start/3` and `job_id/1` dispatch on the job.
7. `Helyx.Session.Queues.clear/1` is deleted. `drop_queues/1` in the server compares with `%Queues{}` and sets `%Queues{}`.
8. `Helyx.Text.read_bounded/1` uses `File.open/3` with a function.

`docs/features/coding-agent.md` and ADR 0004 no longer name a deleted function.

## Bounds sensor

```
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (full)

Simplify, four agents:

- Reuse, 1 finding: the first `drop_queues/1` matched the fields of `Queues`. Changed to `Queues.drain/1`, and changed again in the standards fix below.
- Simplification, 3 findings: the call id was sent twice in the `:start` message (fixed with `job_id/1`). The moduledoc and the `@doc` repeat the cancel contract (skipped: the moduledoc text existed before). The field match in `drop_queues/1` (fixed).
- Efficiency, 0 findings.
- Altitude, 1 finding: the same call id finding. Fixed.

Standards: 0 hard violations and 4 judgement calls. Fixed: `drop_queues/1` uses `%Queues{}`, as the ticket says. Fixed: the feature doc rows said that `request_cancel/2` kills and releases. They now say "the cancel of the hands". Accepted: the untyped `{provider, fun}` job, the `:gen_server` reply protocol in the doc of `request_cancel/2` (ticket item 4), and the `cancel/2` test helper (ticket item 4).

Spec: 2 findings. Fixed: `drop_queues/1` did not use `%Queues{}`. Fixed: the test "a second abort during the sweep drops the messages sent before it" could pass on an earlier `{0, 0}` event. It now asserts the `{0, 1}` event first.

Failure path: 0 findings. The agent read files through `read_file/1` at the limit, one byte over it, with a cut multibyte character, and with no permission, and checked for port leaks. One run failed in the setup at `session_test.exs:1007` (#103 supervisor test, `Helyx.Session.File.append`). The diff does not change that code. Four more runs passed.

## Round 2 (reduced)

The fix changed 6 lines in one code file, `server.ex`, with no function added or removed.

Spec: 3 findings, all fixed. The moduledoc of the hands said that `request_cancel/2` kills the Tasks. The `@doc` of `request_cancel/2` began "Cancels ...". The strict test could not see a wrong event of the first abort, and it did not check that the second abort emits only one event. The agent also noted that `origin/master` moved on after the base (#111). The orchestrator rebases.

Failure path: 0 findings. Probes through `prompt/steer/follow_up/abort` and a Task kill: one event for queues that are not empty, no event for empty queues, and empty queues after the event.

## Round 3 (reduced)

The fix changed doc text in `hands.ex` and one test.

Spec: 1 finding, fixed: the `@doc` of `request_cancel/2` named only tool Tasks. Not in scope: a comment in `server.ex` and one sentence in the feature doc say that only the drain goes out between turns. Both are older than this ticket.

Failure path: 0 findings. The strict test passed 20 times with seeds 1 to 20, and 50 times under CPU load.

## Round 4 (reduced)

The fix changed doc text in `hands.ex` only.

Spec: 0 findings. Failure path: 0 findings.

## Orchestrator

- The rebase on #111 had one mechanical conflict in `docs/features/coding-agent.md`: the Codex line from #111 and the stream shutdown line from this branch are both kept. Precommit ran again after the rebase and passed.
- Codex adversarial review, round 1: no finding.
- Noted, not in scope: one failure of the #103 supervisor test (`test/helyx/session_test.exs:1007`) in round 1 of the worker. It did not recur. The drain-event sentence in `server.ex` and `coding-agent.md` is older than this ticket.
