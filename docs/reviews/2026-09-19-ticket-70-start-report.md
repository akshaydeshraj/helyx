# Review: ticket #70, bash command start after the group marker

Date: 2026-09-19. Branch `ticket/70-exec-report`. Base `origin/master` (`d5e0b1f` for the two review rounds; the branch was fast-forwarded to `667e0a0` before precommit. The #68 change on master touches `lib/helyx/tool.ex`, not the bash tool).

## The change

The watchdog has a second pipe, the report pipe, that closes on `exec`. The held child writes the start line `<nonce> 1` as its last act before the `exec`. When the `exec` fails, or the child ends by `die`, the child writes the reason to the report pipe. The watchdog reads the report pipe one time, after the child ended. If it holds a reason, the watchdog writes the failure report: `<go> 0` and the reason. `<go>` is a second random word. It is the go-ahead line on the watchdog's stdin, so a command cannot know it. `start_report/4` reads the collected output. A failure report anywhere in the output, or no start line after the go-ahead, gives `{:error, "the command did not start: ..."}`.

Invariant: a bash result is ok only when the command reached its `exec`. Every path where the `exec` did not happen gives `{:error, "the command did not start: ..."}`. A command that ran always gives an ok result, and the read of the report never holds the watchdog's kill on a closed port. Documented exceptions: (1) output that was cut in the buffer is an ok result with no start line check, because only a command that ran writes 409,600 bytes; (2) a `kill -9` of the child after the start line and before the `exec` is an ok result with `Exit code: 137`, because no observer can tell it from a kill at the first instruction of bash; (3) perl code that the environment loads into the watchdog (`PERL5LIB`, `PERL5OPT=-M...`) is out of scope, as in #52; (4) `PERL_UNICODE=I` breaks the watchdog's read of stdin after a closed port: ticket #71, not changed here.

## Bounds sensor

Every round printed the same line:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (full, first round)

Simplify, 4 agents.

- Reuse: 1 finding, skipped. Two test files each have a process that stands in for the hands. The two do different things (one sends the registrations to the test, one kills the watchdog), so a shared helper needs a callback for two uses.
- Efficiency: 1 finding, applied. `started/4` tested the same prefix two times and copied the output.
- Simplification: 3 findings, 2 applied (a pinned prefix match in place of the hand-made slice; one prefix test in place of two), 1 applied in part (the long comment lost its repeated sentence).
- Altitude: 2 findings, 0 applied. (1) Read the start line from the stream with `read_marker/4`. Skipped: a failure report with no start line in front is a real path (finding 2 below is false), and `read_marker/4` would return it as `:no_marker` text that needs a second parser. (2) "A failure report with no start line can never occur." False: under `PERL_UNICODE=i` the child's `sysread` of the go-ahead is fatal before the start line. Reproduced, and a test holds it.

Review:

- Standards: 0 hard violations, 6 judgement calls. Applied: `started/4` is now `start_report/4`; the second `pipe` failure has its own message, `report pipe failed`; the comment reflow. Not applied: see "Judgement calls not applied".
- Spec: all 5 acceptance criteria hold. 3 checklist items. (1) The report pipe had no ownership row: row added. (2) The 4,096-byte read of the report has no limit tests: the reason is the path of bash and an OS error text, or a `die` text, and cannot reach the limit from outside; the bounds row now says so. (3) The `kill -9` between the start line and the `exec` used the word "accepted": the row now says why it is not a hole.
- Failure path: 2 findings, both reproduced.
  1. `PERL5OPT=-w` and a bash that cannot be executed gave `{:ok, ...}`. perl wrote a warning about the `exec` between the start line and the failure report, and `started/4` matched the report only at the start of the text. The `<go>` word was then in the text for the model.
  2. The watchdog's read of the report pipe was a blocking read before the poll loop. A held child that got `kill -STOP`, then the go-ahead and a closed port: the watchdog stayed in the read and never killed the group (ADR 0004, release when the owner dies).

Fixes, both to the mechanism. (1) The failure report counts wherever it is in the output. This is safe because only the watchdog holds `<go>`. (2) The watchdog reads the report pipe only after `waitpid` reported the child. The write end is closed by then, so the read cannot wait, and the poll of stdin runs from the go-ahead on. Each reproduction is now a test.

The fix diff in `bash.ex` is over 15 lines and renames a function. Full round.

## Round 2 (full)

Simplify, 2 agents with two angles each (a deviation from the four-agent form).

- Reuse and efficiency: 0 findings.
- Simplification and altitude: 4 findings. Applied: the `case` on a tuple of two independent matches is now one `case` on the split. Not applied: `binmode($r)` on the go-ahead pipe. It makes `PERL_UNICODE=i` work in place of an error. The ticket scope asks for an error on that path and leaves `PERL_UNICODE` to #71; the note is passed to #71. Not applied: `collect/3` without `pre` (it moves up to 4,096 bytes outside the documented buffer bound), and `nonce` and `go` as parameters in place of the two lines (judgement).

Review:

- Standards: 1 hard finding, docs. The new bounds row had a fragment and a sentence with four clauses: the row is rewritten in short sentences. 5 judgement calls, none applied.
- Spec: 0 findings. 37 environment settings (`PERL5OPT`, `PERLIO`, `PERL_UNICODE`, locale, and others): every ok result was a command that ran, and every error result was a command that did not run. Orders of child death and go-ahead on the port: the results are errors. The read of the report pipe cannot wait. 1 note applied: the ownership row said the watchdog always reads the pipe; on the closed-port path it does not. 1 older defect, see "Outside the ticket".
- Failure path: both round 1 reproductions pass. 1 reproduced item: `PERL_UNICODE=I`, a closed port does not kill the group. This is ticket #71, reproduced on master in the #52 record, and out of scope here by instruction. The bounds row now names #71 next to the `PERL_UNICODE` sentence, so the sentence claims only the report pipe. Other cells held: `PERL_UNICODE=S` and `i` give errors, a command that holds the nonce cannot forge a failure report, cut output is ok only after a command ran, a closed port before the go-ahead kills the group.

Round 2 changed no code after the simplify step; the changes after the review are Markdown only. No further round.

## Judgement calls not applied

- The line formats `<nonce> 1` and `<go> 0` are built in perl and again at the one Elixir call site. Two helper functions for two literals add names and remove no risk: the tests fail on any mismatch.
- `pre` goes into `start_report/4` inside the output and as its own argument. The pin `^pre <> rest` asserts the relation; `collect/3` keeps `pre` inside the documented buffer bound.
- `$er` and `$ew` next to `$r` and `$w`. The comment above the watchdog names the report pipe.
- The error text says "the command" two times: `the command did not start: the command gave no start line: ...`. It follows `the watchdog gave no marker`.
- `List.replace_at(args, 5, bash)` in `watchdog_test.exs` depends on the argument order of `launcher/3`. A wrong index fails the test at once, because the expected text names the bash path.

## Outside the ticket

- `PERL_UNICODE=I`: ticket #71 (above). A note for #71: `binmode` on the go-ahead pipe and on the watchdog's standard handles is the likely fix, and it also makes `PERL_UNICODE=i` run the command in place of the error that #70 gives.
- `PERL5OPT=-d`, older than #70, ticket pending: the perl debugger takes the watchdog's stdin, no marker comes, and `read_marker/4` waits without a limit. When the calling process died, the watchdog and its child stayed alive; the child had not called `setpgrp`. No command ran. Found by the round 2 spec agent; the bounds row names it.
- The round 1 failure-path reproduction left a watchdog and a stopped child alive (the defect it reported). They were killed by pid after round 2.

## Precommit

Passed on the final code, on `667e0a0`: root 1 property and 127 tests, `plugins/bundled` 163 tests, `apps/coding_agent` 5 tests, 0 failures.
