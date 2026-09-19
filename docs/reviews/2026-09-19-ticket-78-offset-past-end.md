# Review: ticket #78, a read offset after the last line gives an empty ok result

Date: 2026-09-19. Branch `ticket/78-offset-past-end`, base `origin/master` at `2ac049a`. `origin/master` moved to `e297261` (#86) during the work. The commit is rebased before the merge.

Invariant: for the read tool, `Helyx.Tool.Read.run/2`, an `offset` after the last line of the file is always an error result that names the offset and the line count. It is never an ok result. An offset at or before the last line is never that error. The line count in the error is the total that a truncation notice of `Helyx.Tool.truncate/3` names. The error text, the memory, and the time of the read do not grow with the digits of the offset, and the count uses no memory that grows with the file.

Entry points: `Helyx.Tool.Read.run/2` only. It is the only caller that gives `Helyx.Tool.truncate/3` an offset. `truncate/3` did not change.

Documented exceptions:

- The empty file has 0 lines here, and `truncate/3` counts 1. Offset 1, no offset, and a `null` offset give an empty ok result. A larger offset is the error with `0 lines`.
- Trailing blank lines are lines. An offset at a trailing blank line gives an ok result, and that result can be empty. A truncation notice can name such an offset. It cannot name an offset that gives the error.
- The error shows an offset above 1,000,000,000 as `over 1000000000`. No file within the 10 MiB read limit has that many lines. `truncate/3` gets at most that offset.
- The error repeats PATH as the model gave it, as the older `cannot read PATH` error does. Its only bound is the 10 MiB limit on tool call bytes.

## Simplify, first pass

Four agents: reuse, simplification, efficiency, altitude.

- Efficiency, applied: the count ran before every read and about doubled its cost (148 ms against 124 ms for 10 MiB of 2-byte lines). Now only an empty window after line 1 pays for the count.
- Simplification, applied: function clauses replaced the `if` in `window/3`.
- Reuse and altitude, not applied: move the count into `Helyx.Tool` as a public function. The ticket permits no interface change. A test pins the count to the total of the truncation notice for three line endings.
- Altitude: the read tool is the correct depth. `truncate/3` returns a string and has no other caller with an offset.

## Round 1, complete round

Bounds sensor, base `origin/master`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Standards: 1 documents violation, 6 judgement calls.
  - No devlog. Fixed: `docs/devlogs/2026-09-19-ticket-78-offset-past-end.md`.
  - Applied: `checked/4`, `shown/1`, and `lines/1` got names that say what they do. `lines/1` had the name of a different function in `Helyx.Tool`.
  - Applied: the long sentence in the bounds row became short sentences.
  - Not applied: the literal `1000000000` in the test. The test pins the public text.
- Spec: 0 missing criteria, 3 partial items, 2 overstated statements.
  - No test one under the limit of 1,000,000,000 and no multibyte case. Fixed: 999,999,999 and a path and content with `é`.
  - The row gave no bound for PATH, and `the longest text is 111 bytes` read as if it covered the new error. Fixed.
  - No research citation. Fixed at that time with the opencode end of file note. Round 2 found that the citation did not support the statement.
  - The comment and the moduledoc said that the count is that of `truncate/3`. That is false for the empty file. Fixed: both name the exception.
  - `:binary.matches/2` builds one tuple for each newline. See the failure path.
- Failure path: 1 reproduced finding.
  - `length(:binary.matches(content, "\n"))` on 10 MiB of newlines took 1.0 s and 441 MB. A read with offset 10,485,761 used 763 MB against 368 MB for offset 1. Fixed: a count that builds no list.
  - Probed with no defect: every file of 0 to 5 characters from `a`, `\n`, `\r`, `é` with offsets 1 to 8, the boundary at 1,000,000,000, whole-number floats, the empty file, and the truncation notice.

The fix changed more than 15 lines and renamed functions. Round 2 is a full round.

## Simplify, second pass

- Reuse: clean.
- Simplification, applied: `window/3` and its helper became one `case` and one small function with clauses.
- Simplification, not applied: drop the singular `1 line`. The text is for a model to read, and `1 lines` is wrong English.
- Efficiency, applied: a byte comprehension took 275 ms for 10 MiB. A walk with function clauses takes 23 to 42 ms and also builds no list.
- Altitude: the correct depth within the limits of the ticket. Not applied: remove `@max_shown_offset`. Round 2 showed that the limit is necessary.

## Round 2, full round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Standards: 0 violations. Not applied: rename `empty_window/3` to `empty_window_result/3`, optional.
- Spec: the 4 findings of round 1 are fixed. 2 overstated statements in the docs.
  - The research file records no tool behaviour for an offset after the last line, so the opencode citation did not support the choice. Fixed: the row says that the research has no source for this choice.
  - The row `tool result text` said that the offset after a cut last line `returns nothing`. Fixed: it names `truncate/3` and the #78 error of the read tool.
- Failure path: 1 reproduced finding. 3,000 random files at every offset from 1 to `total + 3`: no failure.
  - A large integer offset made the read slow: 12,294 ms for `10^5000` on 10 MiB of newlines against 534 ms for offset 10,485,761. `Enum.drop(lines, first - 1)` in `truncate/3` subtracts from the big integer one time for each line. The `Enum.drop` is older than this ticket, but the ticket added a comment that said a large integer has no cost. Fixed: the read tool gives `truncate/3` `min(offset, 1_000_000_000)`. A test reads 1,000,000 lines with an offset of 100,000 digits in less than 2 s. Without the fix the same test file took 5.4 s.

The fix is 1 changed line of code and 3 comment lines in one file, with no new function. Round 3 is a reduced round.

## Round 3, reduced round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. A usage limit stopped both agents one time. Both ran again in full.

- Spec: 0 missing, 0 scope creep. The clamp cannot change a result: a file at the read limit has at most 10,485,760 lines, and the comparison and the text use the offset before the clamp.
  - The devlog stated the rebase as done. Fixed: it is a `Next` item.
  - The moduledoc said `names the offset` with no exception. Fixed: one sentence names `over 1000000000`.
  - Not applied: the timing test uses wall-clock time and can fail on a machine under heavy load. The margin is 0.4 s against a limit of 2 s, and 5.4 s without the fix.
- Failure path: 0 findings. Time (364 to 787 ms) and memory (367 MB) stay flat from offset 10,485,761 to `10^5000` and the largest float. The 367 MB is the line list of `truncate/3`, older than this ticket and the same at every offset. A 1,000,000-digit offset on a small file takes 132 microseconds.

The fix is 1 added moduledoc line and Markdown. Round 4 is a reduced round.

## Round 4, reduced round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Spec: clean. Each changed statement agrees with the code. One note: the new moduledoc sentence made one line of 146 characters.
- Failure path: 0 findings. About 1,000 files against an independent line count, with offsets at 1, 2, `total - 1` to `total + 2`, 2000, 2001, 1,000,000,000, 1,000,000,001, and floats. Every offset after the last line gave the error with the true count, and no other offset did. An offset of 1,000,000 digits on 10 MiB of newlines took 0.45 s against 0.76 s for offset 10,485,761.

After round 4 the long moduledoc line got one line break. No word of the text and no code changed, so no round followed it.
