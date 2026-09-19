# Review: ticket #95, an unknown message stops an idle session

Date: 2026-09-19. Branch `ticket/95-unknown-messages`. Base `d17f0b3` (`origin/master`). The change was not committed during the review, so the reviewers read `git diff HEAD` from a patch file.

## Reproduction

The defect is real. The new tests failed before the fix: a message `{ref, {:late_reply, binary, integer}}` to a session in a running turn stopped it with `FunctionClauseError` in `Helyx.Session.handle_info/2`. The error report also formatted the full message, a 100,000-byte binary and a 5,000-digit integer.

Each item that the ticket names exists: `Helyx.Session.handle_info/2`, `Helyx.Hands`, and `Helyx.Core`. Master had a clause that dropped messages only while the state field `aborting` was set (#93).

## The change

`lib/helyx/session.ex`, 25 lines added and 2 removed, comments included. `drop_unknown/2` is the one place that drops an unknown message: it writes one warning and keeps the state. Two callers use it: the `:no_reply` branch of the clause that reads the cancel answer during an abort, and a new last `handle_info/2` clause for every state. `shape/1` makes the log text from the shape of the message only: an atom, or the size of a tuple and its first element when that is an atom. It never formats the message.

`Helyx.Hands` already has a last clause that drops every message. It stays silent, because the exit signal of each tool Task arrives there. `Helyx.Core` is a Supervisor, and its plugin table is an Agent; OTP drops their unknown messages. No code change in the two.

Tests: three, in `test/helyx/session_test.exs`: idle, a running turn, and the sweep of an abort. Each sends a late reply with a large binary and a large integer, a stray atom, and a tuple whose tag is the longest atom (255 characters of U+FFFF). Each checks one line for each message, under 4,096 bytes, and that the session continues.

Invariant: a message that no other `handle_info/2` clause of `Helyx.Session` takes never stops the session and is never formatted; the session drops it with one warning under 4,096 bytes. Entry points: the last `handle_info/2` clause (idle and a running turn) and the `:no_reply` branch of the abort clause (the sweep of an abort). Both go through `drop_unknown/2`.

Documented exceptions, in the bounds row of `docs/features/coding-agent.md`: the number of log lines has no cap of its own. The clause covers `handle_info/2` only, so a cast or an unmatched call still stops the session. `Helyx.Hands` writes no log line. The OTP line of `Helyx.Core` formats the message, and the `:truncate` of `Logger`, 8,096 bytes, is its bound.

## Bounds sensor

```text
bounds sensor skipped
```

## Round 1 (full, first round)

Simplify, 4 agents.

- Reuse: 0. Efficiency: 0.
- Simplification: 2, both applied. The first form had one clause for all states with a private `cancel_response/2` and a second match on `state.aborting`. The abort clause keeps its head now, and the two paths share `drop_unknown/2`. `shape/1` lost a nested `case` for flat guard clauses, and `{}` reports its size.
- Altitude: 0 blocking. 1 optional, the same second match; applied with the item above.

Review, 3 agents.

- Standards: 0 hard violations, 6 judgement calls. Applied: a comment that gives the reason for `elem/2` (the checklist rule "never elements by index" is about plugin values that reach state), the name `assert_unknown_dropped/1` for the test helper, a comment on the call that is the barrier, the cell style of the bounds row, and "arrives" for "lands". Not applied: the name `shape_text/1` (the comment says what the function returns, and a rename makes the rerun a full round), and a devlog (no ticket commit of this run has one).
- Spec: 1 partial, 1 docs. No test was at the bound: applied, the test sends a tag of 255 characters of U+FFFF and checks each line against 4,096 bytes. The row did not say that the OTP line of Core formats the message: applied, with the `Logger` truncation as its bound.
- Failure path: 1 finding, reproduced, older behaviour, outside the ticket. `GenServer.cast(pid, :x)` stops the session with `RuntimeError` (no `handle_cast/2`), and `GenServer.call(pid, :bogus)` stops it with `FunctionClauseError` in `handle_call/3`. The first text of the bounds row said "every unknown message"; the row now names `handle_info/2` and states this limit. **accepted with no ticket (only code inside the node can send it, and that code is trusted; the default limits of `inspect/1` bound the text of the hands)**. Probes with no defect: the worst line was 2,127 bytes; `{}`, a list, a map, a pid, a binary, an integer, `nil`, `{1, 2}`, a stray `:DOWN`, a 4-tuple `:EXIT`, `{ref, :ok}`, and `{:system, 1}` were dropped with one line each; the 59 older session tests write no "dropped an unknown message" line.

## Round 2 (reduced)

The fix of round 1 changed 2 lines of code, both comments, in one code file, plus tests and Markdown. It adds no function and changes no arity, so the round is reduced: spec and failure path. Both briefs named the invariant.

- Spec: 0 findings. 1 inexact number in the row: `inspect/1` writes a character as 8 bytes at most, not 10. Corrected, Markdown only. The agent verified the `:truncate` default of 8,096 bytes (Elixir 1.19.5), the `?LOG_ERROR` line of `supervisor.erl`, and the default `handle_info/2` of an Agent.
- Failure path: 0 findings in the change. 2 reproduced defects in older clauses that the diff does not touch; `origin/master` has both. A local process must forge a message with a known tag to reach them.
  - A forged `{:stream_event, turn_id, event}` with the current turn id and a bad event (`:garbage`, `{:text_delta, 5}`) stops the session in `Message.add_block/2`, and the crash report formats the event. The turn id is in every event. `{:tool_result, turn_id, call_id, result}` has the same form; not run. **accepted with no ticket (only code inside the node can send it, and that code is trusted; the default limits of `inspect/1` bound the text of the hands)**
  - `{:EXIT, x, reason}` with an `x` that is not a provider pid stops the session, also for an `x` that is not a pid or was never linked. The comment on the clause says the stop is by design for linked processes; a mailbox message of that shape cannot be told apart from an exit signal. **accepted with no ticket (only code inside the node can send it, and that code is trusted; the default limits of `inspect/1` bound the text of the hands)**
- Seen by the spec agent, older, not run: `lib/helyx/hands.ex:186` calls `inspect(reason)` on the `:DOWN` reason of a tool Task, a term of unbounded size. **accepted with no ticket (only code inside the node can send it, and that code is trusted; the default limits of `inspect/1` bound the text of the hands)**

No code changed after round 2, so round 2 is the last pass.

## Precommit

Passed, no warnings. Root: 1 property, 145 tests, 0 failures. `plugins/bundled`: 198 tests, 0 failures. `apps/coding_agent`: 13 tests, 0 failures. No test writes a "dropped an unknown message" line that it does not capture.
