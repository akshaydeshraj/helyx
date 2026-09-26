# Review: a write after the go-ahead to a dead watchdog (#167)

Base: `origin/master` at `ca7081d`. Five rounds: the first round, then four full rerun rounds. Rounds 1 to 4 describe the trap design that round 5 replaced.

## Change

A write to a watchdog that died after the go-ahead closes the port with `:epipe` and sends no exit status. The final design (round 5):

- Codex traps exits from its start, as before. Its read loop takes a port exit that is not `:normal` as the end of the run, through its existing `exited/2`: the terminal is `{:error, {:codex_exit, :epipe}}`, unless a terminal came before it. It keeps its interrupt path.
- Claude Code does not trap exits, except in the short go-ahead of `Helyx.Watchdog.start/4`. After the start and before its input write, `Helyx.HarnessIO.keep_port/1` moves the port's link to a keeper process. The keeper traps exits, is linked to the Task and to the port, and closes the port when the Task ends. The Task monitors the port. Its read loop takes the port's `:DOWN` as the end of the run: the terminal is `{:error, {:claude_code_exit, :epipe}}`, unless a terminal came before it. A `:lost` terminal still starts the fresh run. The input is its own write, ended by a NUL.

Invariant: no harness stream Task ends on the `:epipe` exit signal, and the shutdown of the hands ends the Claude Code stream Task at once in every phase (first start, read loop with queued stdout, a lost session's fresh run). The port closes whenever the Task ends, so the watchdog ends the group (ADR 0004).

Owner decision (2026-09-26, on #167): "Claude Code traps exits for the life of the port, as Codex does." The final design meets the intent of the decision but not its words. `:epipe` fails the turn with `{:claude_code_exit, :epipe}`, and any other exit signal ends the Task as before. The keeper traps exits, not the Task. The reason is four findings on the trap (rounds 1, 2, 4, and 5): with the trap on, a shutdown of the hands is a message, and it waits behind every step and every message before it. This needs the owner's confirmation.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

The same output in all five rounds.

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

## Round 5

Full round, after the Codex round 2 review of the branch. This was the fourth finding on one mechanism, the trap of the Claude Code stream, so the fix removes the trap.

### Codex finding

Fixed, reproduced: the Claude Code read loop trapped exits, so a shutdown of the hands waited behind all stdout that was queued before it. The line cap bounds each line, not the number of lines. Codex probe: 6,000 queued lines of about 64 KB; the Task was alive 2,000 ms after the shutdown. Fix: the structural option (a). A plain unlink of the port was probed and rejected: a port with no link stays open after its owner dies, which breaks ADR 0004. So `Helyx.HarnessIO.keep_port/1` moves the link to a keeper process that traps exits and closes the port when the Task ends, and the Task monitors the port. The Task does not trap exits, so `pass_exits/0` and the trap flags in `ClaudeCode.start/2` are gone. Test: "a shutdown behind queued stdout ends the stream at once" (1,000 queued lines of 64 KB, a 200 ms bound, then the group is gone; red 3 of 3 runs on the round-4 code). The checklist line now states the structural rule: a Task that a shutdown must end at once does not trap exits.

### Simplify

No code change. Skipped: flush the port monitor in `stop/1`; a stale `:DOWN` stays only in the mailbox of a Task that is ending, and the read loop drops the `:DOWN` of a lost run's port.

### Standards

No hard violations. Fixed: the `HarnessIO` header now names the keeper. Skipped: move `keep_port/1` into `ClaudeCode`; it is port handling of a harness provider and the checklist names it as the pattern. Skipped: the name `keep_port/1`; its comment says what it does.

### Spec

1. Fixed: `coding-agent.md` said "never traps exits"; the go-ahead of `Helyx.Watchdog.start/4` still traps for one write and a port check. The line now names that exception.
2. Fixed: this record described the trap design as final. The Change and Owner decision sections now describe the keeper.

### Failure path

No findings. Probed through `stream/3`: a `:kill` in the read loop, a normal end with no `stop/1`, a shutdown after a lost session's fresh run, and a normal completion. In each case the group was gone and no keeper was left. The keeper states before and after the unlink were checked by reasoning.

## Out of scope, reported

- Codex traps exits from its start, as before this change, so a shutdown during its start (a hold call to the hands) waits the 2,000 ms kill. The same holds for its replay build after `thread/start`, whose time grows with the transcript. `coding-agent.md` states both.
- In the Codex interrupt path, `receive_end/3` does not take an `:epipe` port exit; its 1,000 ms wait bounds it.
