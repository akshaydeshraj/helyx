# 2026-09-19: ticket #78, a read offset after the last line

## Done

- Every name in the ticket exists: `Helyx.Tool.truncate/3`, the `offset` argument of the read tool, and the bounds row `read tool offset`.
- An `offset` after the last line is now an error result: `offset N is after the last line: PATH has T lines`. The ticket preferred the error.
- The fix is in `Helyx.Tool.Read`. `Helyx.Tool.truncate/3` has one caller with an offset, the read tool, and its spec returns a string. It did not change.
- The read tool counts lines only when the window is empty and the offset is more than 1. The count is one pass over the bytes and builds no list.
- An empty file has 0 lines. Offset 1, no offset, and a null offset give an empty ok result. A larger offset is the error.
- Trailing blank lines are lines. An offset at a trailing blank line gives an ok result, and that result can be empty. A truncation notice can name such an offset. It cannot name an offset that gives the error.
- The error shows an offset above 1,000,000,000 as `over 1000000000`, so the text does not grow with the digits of the argument.

## What broke

- The first count used `:binary.matches/2`. The failure-path review measured 441 MB for a file of 10 MiB of newlines. A walk over the bytes with function clauses replaced it. A byte comprehension was 6 to 12 times slower.
- The read passed a large integer offset to `truncate/3`, which subtracts from it one time for each line. The failure-path review measured 12 s for `10^5000` on 10 MiB of newlines. The `Enum.drop` is older than this ticket, but the ticket made a claim about the cost. The read tool now gives `truncate/3` at most 1,000,000,000.
- The worktree started one merge behind `origin/master` (#86).

## Next

- Rebase the commit on `origin/master` before the merge.
- Nothing more for this ticket. The slow JSON encode of a large integer argument stays with #79.
