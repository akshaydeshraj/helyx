# Review: a write after the go-ahead to a dead watchdog (#167)

Base: `origin/master` at `ca7081d`. Four rounds: the first round, then three full rerun rounds.

## Change

A write to a watchdog that died after the go-ahead closes the port with `:epipe` and sends no exit status. Each harness provider's read loop now takes a port exit that is not `:normal` as the end of the run, through its existing `exited/2`: the terminal is `{:error, {:claude_code_exit, :epipe}}` or `{:error, {:codex_exit, :epipe}}`, unless a terminal came before it. A `:lost` terminal still starts the fresh run. `Helyx.Provider.ClaudeCode` now traps exits from the go-ahead on. It starts the watchdog with open input and writes its input as its own write, ended by a NUL. Before the start, it turns the trap off and acts on the exit messages that the trap made (`pass_exits/0`), so a shutdown of the hands ends the start at once. Any other exit signal acts as it would without the trap. Codex keeps its trap from the start and its interrupt path.

Invariant: no harness stream Task ends on the `:epipe` exit signal, no stream waits past its deadline or an abort because of it, and the shutdown of the hands ends the Claude Code stream Task at once in every phase (first start, read loop, a lost session's fresh run).

Owner decision (2026-09-26, on #167): "Claude Code traps exits for the life of the port, as Codex does." The code traps from the go-ahead on, not from the port open. The reason is the round-1 finding below: a trap during the start makes the hands' shutdown wait 2,000 ms, which breaks "the hands' shutdown still stops the Task" of the same decision. No write is pending between the port open and the go-ahead, so no `:epipe` can come before the trap. This needs the owner's confirmation.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

The same output in all four rounds.

## Round 1

### Simplify

Four agents. Efficiency and altitude: no findings. Skipped: reuse proposed a bound on the test poll loop; the stream process's 5,000 ms kill ends it, and a comment now says so. Skipped: simplification noted that the exit clauses of the two providers differ; the difference is deliberate (Claude Code had no trap, Codex interrupts first), and a comment now says so.

### Standards

No hard violations. Skipped judgement calls: `exited/2` gets an exit status or an exit reason under the name `status`; the test module has no `lib/` counterpart, as `watchdog/go_ahead_test.exs`; the setup repeats the fake perl of `go_ahead_test.exs` (two copies). The branch base was one docs commit behind `origin/master`.

### Spec

1. Fixed: `coding-agent.md` said "A stream that does not trap exits dies at once, as before", with no word on the new Claude Code trap. The Stream Task shutdown line now states when each harness stream traps exits.
2. Same mechanism as the failure-path finding below: a shutdown during the Claude Code start waited for the first read.

### Failure path

1. Fixed, reproduced: with the trap set before the start, an abort while the start waits in its hold call to the hands (which wait in `Task.shutdown/2`) waited the full 2,000 ms and ended in a kill. Before the change, the Task ended at once. Fix: the trap starts after the go-ahead; the input is its own write after it. Test: "Claude Code: a shutdown of the hands during the start ends the stream at once" (red on the round-1 code).

## Round 2

Full round: the fix changed 20 code lines and the input path of Claude Code.

### Simplify

Four agents. No findings to apply. Altitude called `Process.flag(:trap_exit, false)` a no-op; it is not, a lost session's fresh run enters `start/2` with the trap on. A comment now says so.

### Standards

No hard violations. Fixed: the test bound `stream` to a pid and, inside, to an enumerable; the pid is now `pid`. The comment on the test name now says why it holds no quote.

### Spec

1. Fixed, same as failure path 1.
2. Reported: the trap from the go-ahead does not meet "for the life of the port" literally (see Owner decision above).

### Failure path

1. Fixed, reproduced: a shutdown that came behind a lost run's exit status stayed a message after the fresh run turned the trap off, so the fresh run's hold call waited the 2,000 ms kill. This was the second finding on one mechanism, the trap around the Claude Code start, so the fix covers every entry to `start/2`: the trap goes off, then `pass_exits/0` acts on every queued exit message as an untrapped process would, and drops port exits, which can only be from the lost run's closed port. Test: "a shutdown queued behind the exit of a lost run ends the stream before the fresh run" (red on the round-2 code).

## Round 3

Full round: the fix adds a function.

### Simplify

Four agents. Fixed: a comment in `start/2` did not parse. Skipped: reuse and simplification proposed one drain helper with `Helyx.Watchdog.pass_exits/1`; that one must keep its own port's exit for its caller, and this one must drop port exits, so a shared helper would change the watchdog outside this ticket.

### Standards

No hard violations. Skipped: the test poll `wait_for_exit_status/2` repeats the shape of the poll helpers; no other test polls a mailbox.

### Spec

No findings. The docs match the code.

### Failure path

No reproduced findings. Probed: `exit_timeout(:lost)` then a shutdown at the fresh run's hold; a shutdown queued after the lost deadline; a stale `:epipe` from the lost run's port (`Port.close/1` sends `:normal` at once and no later signal); an exit between the trap-off and `pass_exits/0`; the input write to a port that does not read.

## Round 4

Full round, after the Codex round 1 review of the branch. This is the third finding on one mechanism, the trap around the Claude Code start.

### Codex finding

Fixed, reproduced: a lost session's fresh run entered `start/2` with the trap on and built its input and argv before the trap reset and `pass_exits/0`. The build takes time that grows with the transcript, so a shutdown of the hands waited for it. Fix: the trap reset and `pass_exits/0` are the first operations of `start/2`. Test: "a shutdown queued behind the exit of a lost run ends the stream before the fresh run" now has a transcript of 1,000,000 messages and a 200 ms bound (red on the round-3 code: 660 ms, and 2.8 to 3.5 s in the failure-path check). `review-checklist.md` has a new line under "Races and resource ownership": a Task that traps exits turns the trap off before work whose time grows with an input that has no cap, on every path into the function.

### Simplify

Four agents. Reuse, efficiency, and altitude: no findings. Skipped: simplification proposed a test hook in production code in place of a test that depends on time; the test comment states the time bound and the measurement.

### Standards

No hard violations. Skipped: the history append copies the list once, in the setup, outside the timed part.

### Spec

1. Fixed: the new checklist line said that every read-loop step is bounded by its line cap. The Codex read step after `thread/start` builds the replay from the whole transcript with the trap on. The checklist line now limits the exemption to a step that only parses a line, and the Stream Task shutdown line of `coding-agent.md` states the Codex case as open.
2. Fixed: this record had no round 4.

### Failure path

No new findings. The regression test fails 3 of 3 runs on the old order. Probed: the input write with a prompt of 1, 100, and 400 MB to a program that does not read (the shutdown ended the Task in 0 to 2 ms); `HarnessIO.stop/1` in `exit_timeout/1`; a read-loop step; `pass_exits/0` after the trap reset.

## Out of scope, reported

- Codex traps exits from its start, as before this change, so a shutdown during its start (a hold call to the hands) waits the 2,000 ms kill. The same holds for its replay build after `thread/start`, whose time grows with the transcript. `coding-agent.md` states both.
- In the Codex interrupt path, `receive_end/3` does not take an `:epipe` port exit; its 1,000 ms wait bounds it.
