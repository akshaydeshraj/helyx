# Review: go-ahead write to a dead watchdog (#131)

Date: 2026-09-26. Base: `origin/master` at 79c0604. Ticket #131. Spec: the ticket and the row "bash command start after the group marker" of `docs/features/coding-agent.md`. Follow-up: #167.

## Cause of the flake

A probe showed the form of the failure. A port whose program closed its stdin, but whose stdout stays open, takes `Port.command/2`: the call returns `true`, the port closes with the exit reason `:epipe`, and it sends no exit status. The exit signal `:epipe` goes to the linked owner. An owner that does not trap exits dies with it. In `bash_test.exs` ("a watchdog killed before the go-ahead"), the watchdog is dead and the port has not yet read end of file and the exit status when the go-ahead is written. In the usual order the port is already closed, `Port.command/2` raises, and `write/2` rescues it. The flake is the other order.

## Invariant

`Helyx.Watchdog.start/4` is the entry point for the bash tool (`run/2`) and for `Helyx.HarnessIO.start/5` (Claude Code and Codex). The watchdog is the boundary. The go-ahead line is its own write and the first write on the watchdog's stdin pipe, so the pipe takes all of it or the write fails at once. A go-ahead write that raises (the port is closed) or that gets `EPIPE` (the port exits `:epipe`) gives `{:failed, "the perl watchdog died before the go-ahead: ..."}`, and the caller does not exit, whether it traps exits or not. The bash tool gives `the command did not start: ...`, and `HarnessIO` gives `{:error, {:not_started, _}}`. Other exit signals keep their effect on a caller that does not trap exits. A `:normal` close after a go-ahead that the pipe took leaves the result to the reader, so a command that ran is never reported as not started. The input of Claude Code is a later write. A later write to a dead watchdog is open, ticket #167.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (4 agents): reuse 3, simplification 4, efficiency 0, altitude 4.

- Fixed: the test cleanup reads the pid with `wait_for_pid/1`.
- Fixed: the `cond` of `go_ahead/2` became one `if`.
- Fixed: the comment of `write/2` names the `:epipe` case.
- Skipped: a shared helper for the fake `perl` on PATH and for the hands stand-in. The copies are short and test-only.
- Skipped: `Process.unlink/1` of the port in place of the trap. A probe showed that an unlinked port does not close when its owner dies, and the abort needs that close.
- Deferred to round 2: the Codex later write (altitude), and the name `:no_marker` for a result that had a marker.

Standards: 0 hard, 7 judgement calls. Fixed in round 2: the tag name (`{:no_marker, _}` of `start/4` is now `{:failed, _}`) and the missing doc line.

Spec: 4 findings. Fixed in round 2: a go-ahead write to a closed port gave `{:started, ...}`, the trapping caller had no test, and the doc had no line. Accepted: `port_exit/1` exits with an unknown port reason, as the signal would have; no write error other than `EPIPE` is known.

Failure-path: 1 finding. A go-ahead with input larger than the pipe (Claude Code, 400,000 bytes) left the rest in the port's queue. A watchdog that died later made the queued bytes get `EPIPE`, and the exit signal ended the caller. Fixed in round 2.

## Round 2 (full)

The fix added a wait for the port's queue (`drain/2`, a poll of 1 ms), renamed the tag, and added tests for a trapping caller and for queued input.

Simplify (2 agents, 4 angles): 2 fixed (the `write/2` comment points to `go_ahead/2`; the poll comment states its cost), 3 skipped (a test helper, the state map, a receive in place of the poll with the same scans).

Standards: 2 hard. The `ponytail:` marker named no ticket, and the doc named an open hole with no ticket. Fixed in round 3: the poll is gone, and the hole is #167.

Spec: 1 finding. A `:normal` close with queued input gave a different result than the doc said. Closed in round 3.

Failure-path: 1 finding, the second on the same write mechanism. An `EPIPE` on queued input proves only that the input was not delivered. A command that ran and exited, with a background child that held stdout, was reported as not started (10 of 10 runs). By the rule "two findings on one mechanism", round 3 fixed the mechanism: the go-ahead is its own write and is never queued, and the input is a later write. #167 records the later writes (Claude Code input, Codex lines) and the decision it needs: the terminal error of a stream whose watchdog died after the go-ahead.

## Round 3 (full)

The fix removed `drain/2`, split the input from the go-ahead, and named #167 in the doc.

Simplify (1 agent, 4 angles): 1 fixed (a test that became a duplicate was removed), 1 fixed (the `write/2` comment names #167), 1 skipped (the internal `:no_marker` of `read_marker/4` is correct).

Standards: 0 hard, judgement calls. Fixed: the ownership rows name #167, the bash comment says "names perl", the test helper is `kill_and_await/2`. Skipped: the empty text after "died before the go-ahead: " follows the pattern of the no-marker text.

Spec: 0 findings. Noted: a port that closes after `Port.info/2` inside the trap leaves a message in the mailbox; a comment now says so.

Failure-path: 0 findings. 600 runs of a concurrent kill (397 `:failed`, 203 `:started`, no caller death, no hang, no command ran). 40 runs with a busy port (`yes` on stdout): the order of `Port.info/2` after the write holds.

## Round 4 (full)

The fix changed comments in two code files, doc cells, and a test helper name. Two code files, so the round is full.

Simplify (1 agent, 4 angles): 1 fixed (the command port cell is shorter), 1 skipped (the ownership rows of the providers keep their own #167 note, as the checklist asks).

Standards: 0 hard, 3 judgement calls. Fixed: the comment names `Port.info/2`, the #167 wording is the same in each row, the command port cell no longer names #167 (the bash tool makes no later write; also spec).

Spec: 0 findings (the #167 note in the bash row, fixed above).

Failure-path: 0 findings.

## Round 5 (reduced)

The fix changed one comment (4 lines) and two doc cells.

Spec: 1 finding. The comment said no receive takes the late port exit; Codex traps exits and its `receive_next/2` takes it. Fixed: "which no receive of `go_ahead/2` takes".

Failure-path: 0 findings.

## Round 6 (reduced)

The fix changed one comment line.

Failure-path: 0 findings.

Spec: 0 findings. Noted, not changed: the comment of `port_exit/1` says "as the signal would have", which is not true for Codex, which traps exits; no port reason other than `:normal` and `:epipe` is reachable.

## Round 7 (full)

The first precommit failed: Credo strict reported "Function body is nested too deep" in `handshake/3`. The fix moved the input write into `write_input/2`, a new function, so the round is full.

Simplify (1 agent, 4 angles): clean.

Standards: 0 hard, 0 judgement calls. Noted, not changed: the second clause of `write_input/2` could name `nil` and `:open`.

Spec: 0 findings.

Failure-path: 0 findings.

## Runs

The full bundled suite ran 50 times after round 6: 50 of 50 passed (325 tests and 1 property each), with the test "a watchdog killed before the go-ahead" of `bash_test.exs` in every run.

Precommit passed after round 7 (root 194 tests; bundled 325 tests and 1 property; coding_agent 17 tests).

## Orchestrator

- Rebased on #150, #153, and #148. One mechanical conflict in the Ownership paragraph of `docs/features/coding-agent.md`: the text of #150 was kept and the #131 clause added. Precommit passed after the rebase.
- Codex adversarial review, round 1: no finding.
- An EPIPE on a write after the go-ahead is out of scope and filed as #167.
- Not changed: the comment on `port_exit/1` says "as the signal would have", which is not exact for Codex, because Codex traps exits. No other port exit reason can occur there.
