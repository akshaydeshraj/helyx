# Review: ticket #52, bash working directory the port cannot enter

Date: 2026-09-19. Branch `ticket/52-bash-cwd`. Base `origin/master` (`150a1c1`).

## The change

The port has no `cd` option. The perl watchdog does the `chdir` itself before it forks. A `chdir`, `pipe`, or `fork` that fails writes the marker `<nonce> 0` and the OS reason; the result is `{:error, "the command did not start: ..."}`. A marker line is `<nonce> <number>`; the nonce is 8 random bytes for each call and reaches the watchdog in its arguments only. The tool reads past at most 4,096 bytes of other lines to find the marker. Only a group marker, registered with the hands first, leads to the go-ahead and to an ok result. With no marker the tool closes the port and returns an error.

Invariant: a bash result is ok only after the watchdog wrote a group marker that the hands hold, and no text on the merged stream can pass for a marker.

## Bounds sensor

Every round printed the same line:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (full, first round)

Simplify, 4 agents: 1 altitude finding applied (`pipe` and `fork` failures used `exit 91`, the same defect as #52; they now use the start-failure marker). 1 stale comment fixed. 1 skipped (a tagged result for `consume`, judgement).

- Standards: 0 hard violations, 5 judgement calls. Applied: the test name and the comment reflow. Not applied: result shapes and names, see "Judgement calls not applied".
- Spec: 0 defects. 4 small items, all applied: the bounds row names `pipe` and `fork`; the reason goes through `Helyx.Tool.truncate/2`; the test asserts the OS reason; the ownership text.
- Failure path: 1 medium, reproduced. With `LC_ALL=xx_NOPE.UTF-8` perl writes a locale warning to the merged stream before the marker. The first line was then not a marker, so a removed directory gave `{:ok, ...}` with exit status 0. On master the same warning made the command run with no registered group. Fix: `read_marker` reads past lines that are not a marker, within 4,096 bytes. 1 low, not a defect in the real flow: a working directory with invalid UTF-8 gives invalid error text from a direct `run/2`; the hands scrub every result (`scrub/1`).

## Round 2 (full: more than 15 lines, a new test file)

Simplify, 3 agents (one agent took the reuse and the efficiency angle; a deviation from the four-agent form): 1 comment reflow applied, 2 minor skipped.

- Standards: 0 hard violations, 4 judgement calls, none applied.
- Spec: 2 defects by reading and plain perl. (1) A watchdog that exits before the marker (`PERL5OPT=-MNopeNope`) gave an ok result with perl's exit status 2. (2) A preamble over 4,096 bytes (a 5,000-byte locale variable) gave the go-ahead with no registered group. Also: no bounds row for the preamble, and limit tests missing for the sum of lines and the partial line.
- Failure path: reproduced (2) two ways: ok result for a removed directory, and a command that ran with only the `:watchdog` group registered.

This was the second finding on the marker read, so the fix went to the mechanism (checklist, "Two findings on one mechanism"): a missing marker is never output. `:no_marker` closes the port and is an error; only a group marker leads to the go-ahead. Tests added for every limit case, the truncated reason, `PERL5OPT`, and the 5,000-byte variable.

## Round 3 (full: mechanism change, `close/1` added)

Simplify, 4 agents: 1 comment added, 2 helper extractions skipped, 0 altitude findings.

- Standards: 0 hard violations, 4 judgement calls, none applied.
- Spec: 2 defects by plain perl. A newline in a locale variable puts any line in the warning, so `LC_ALL="xx\n4242\nyy"` forged a group marker, and `PERL5OPT=-d` with `PERL5DB` printed one. Also: no test for the processes on the close path, the port's ownership row did not name the close.
- Failure path (it ran on the code before the nonce): reproduced the forged group, and a forged `0` line that made `run/2` wait forever with two perl processes alive. That one was new in this diff. It confirmed that the nonce code closes both.

Third finding on the marker, so the marker itself changed: `<nonce> <number>`. Text from the environment cannot hold the nonce. Tests added: lines without the nonce, a forged line from the environment, no process left after the close. The ownership row names the close.

## Round 4 (full: `launcher/3`, `read_marker/4`, `parse_marker/2` changed arity)

Simplify, 4 agents: 1 comment rewrite applied. Skipped: `Helyx.Id.new/0` for the nonce (internal to the root project, no plugin calls it), and one directory in a test loop (it holds a separate claim).

- Standards: 0 hard violations, 5 judgement calls, none applied.
- Spec: 0 new paths. `PERL_UNICODE=S`, `PERL5OPT=-T`, and `PERL5OPT=-t` fail safe. 3 text items, all applied: the "first 4,096 bytes" wording, the comment "no ok result without a command" (false for a failed `exec`, exit status 127, as on master), the wording of the close path.
- Failure path: the required tests pass. 2 reproduced items, both also on master. (1) A `POSIX.pm` on `PERL5LIB` that reads `@ARGV` writes a marker: the user's own perl code in the user's own environment, stated as out of scope in the bounds table. (2) A `kill -9` of the watchdog between the marker and the go-ahead gives an ok result with `Exit code: 137` for a command that never ran. This and the failed `exec` are one hole, "bash command start after the group marker", stated in the bounds table as open, ticket #70. It is outside #52: the child has no channel to say that the `exec` happened.

Fix: comments and Markdown only, 6 comment lines in one file, no function changed. Reduced round.

## Round 5 (reduced: spec and failure path)

- Spec: all 5 acceptance criteria hold. 1 low: the limit counted the noise but took a marker at any position in the same message, so 4,095 noise bytes and a newline gave the group in one buffer and `:no_marker` when the marker came in the next message. Both results were safe. 1 minor: "passes the limit" in a comment.
- Failure path: the same limit item, reproduced. 1 more, also on master: `PERL_UNICODE=i` makes the child's read of the go-ahead fail before the `exec`, so the result is ok with `Exit code: 255` for a command that never ran. It is the open hole "bash command start after the group marker"; the row now names it.

Fix: one rule in `read_marker/4`. A line, marker or not, counts only if it ends within the first 4,096 bytes of the stream. Tests at the limit, one under, one over, multibyte, the sum of lines, and the message cut. The fix diff in `bash.ex` is 25 lines with comments, over the 15-line rule.

## Round 6 (full)

Simplify, 2 agents with two angles each (a deviation from the four-agent form): 2 test cleanups applied (a dead mailbox drain, an exact assertion in place of a loose one). 0 findings on the code.

- Standards: 0 hard violations, 4 minor judgement calls, none applied.
- Spec: the rule holds for every cut, traced by hand; all 5 criteria hold. 1 comment item: the marker result is free of the message cut, the `:no_marker` text is not. 1 item outside the ticket, see below.
- Failure path: 0 findings. 216 streams with 60 random cuts each, the exit status at each position, and a sweep of the limit through the real port: the result is ok if and only if the command ran.

Fix: 3 comment lines in `bash.ex` and one sentence in the bounds row. No function changed.

## Round 7 (reduced: spec and failure path)

- Spec: 0 findings.
- Failure path: 0 findings. Cuts into three messages over 10 preamble lengths and 6 tails, with cuts inside the nonce and inside a multibyte character: no cut changes the marker result.

## Judgement calls not applied

- `consume/2` returns `{:not_started, reason}` or `{output, dropped?, status}`, and `read_marker/4` has the group integer in the tag position. Private functions, matched in one place each; tagged `{:ok, _}` wrappers add a level and no check.
- `close/1` and `go_ahead/1` share a rescue body. Two uses.
- `pre` and `acc` in `read_marker/4`. The comment above names them.
- `bash_preamble_test.exs` mirrors no `lib/` file, as `watchdog_test.exs` and `vm_kill_test.exs` do.

## Outside the ticket

- `PERL_UNICODE=I` in the environment (a value that also holds `S` or `O` is safe: the marker write fails first and the result is an error): the watchdog's `sysread(STDIN, ...)` on the closed port fails on a `:utf8` handle, so the watchdog ends and does not kill the group. Reproduced through `launcher/3` and a closed port: the command was alive 1.5 s later. The same perl lines are on master. It breaks the ownership row "command process group" for the owner-death path (ADR 0004); abort still works, because the hands kill the registered group. A `binmode` on the watchdog's handles, or a removal of `PERL_UNICODE` from its own environment with a restore before the `exec`, is the likely fix. Not fixed here; the orchestrator files it.

- "bash command start after the group marker" (above): ticket #70.

## Precommit

Passed on the final code: root 1 property and 107 tests, `plugins/bundled` 147 tests, `apps/coding_agent` 5 tests, 0 failures.
