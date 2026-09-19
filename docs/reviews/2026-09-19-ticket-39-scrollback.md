# Review: ticket #39, TUI transcript scrollback

Date: 2026-09-19. Scope: `Helyx.TUI` (`on_screen/2`, `settle/1`, `hold/4`, `scroll/4`, `back/4`, `forward/3`, `rows_from/3`, `transcript_widget/3`, the status bar), its tests, and the TUI rows of `docs/features/coding-agent.md`.

## Invariant

The scroll position is nil, or it is a cell index and a row. Its row is a row of its cell, and the rows from it to the end of the transcript are more than one screen of the size that `terminal_size_fn` gives. With no size the position is nil. Thus a scrolled screen is full, and the status bar says `scrolled` only then. One check, `hold/4`, makes every position that is not nil. One function, `on_screen/2`, reads the size. Entry points: the `page_up` and `page_down` keys, `end` with `ctrl`, an accepted steer or follow-up, each session event (`handle_info/2`), a `/model` line, and `ExRatatui.Event.Resize`.

Documented exceptions, all in the bounds row: the position is an index and a row, not an identity, so a new width, a tool result in the first cell on the screen, or a client notice that takes the index of the open message moves the text under the position. The check runs at the entry points and not on each frame. At a terminal height of 4 rows or less the transcript has no row.

## Measurement

Width 100, cells of 851 bytes and 11 rows. A wrap of all cells: 4.6 ms for 100 cells, 82 to 90 ms for 1,000, 1.8 to 2.2 s for 10,000. A frame runs for each event, so the design wraps no more than the cells near the screen, and there is no cache. With 10,000 cells: a scrolled frame 0.3 ms, a PgDn 0.9 ms, the first PgUp 4 ms.

## Bounds sensor

All rounds: `bounds sensor skipped: TYPESAFE_API_KEY is not set`

## Simplify

- Round 1: applied 5. One source for the layout rows (`@composer_rows`, `@status_rows`). One mechanism for the first row of the follow view (`bottom/3`), which replaced the old tail path. A clause for PgDn in follow mode. The position passed as one value. A comment. Not applied: no copy of the cell list for the open message (the cost was there before), no end check for PgUp (the check is the invariant).
- Rounds 2, 3, and 4: clean. Optional items not applied: a size kept in the state, rows returned from `back/4`, a second wrap of one cell in `hold/4`.

## Round 1 (full)

- Standards: no test at the limit of the screen rows, no wrapped cell, no multibyte case. Fixed: tests for heights 6, 5, 4, 3, and 0, a cell of wide glyphs, and the 4, 5, and 6 row limit of `hold/4`.
- Standards: the state key `size_fn` and the option `:terminal_size_fn` had two names. Fixed. The measured numbers were in a comment and in the doc. The comment now points to the doc.
- Spec: the criterion of the line cache is met with no cache and the measurements in the row. The idle key help was cut earlier at 80 columns. `PgUp scroll` is now last.
- Spec and failure-path, one root cause, reproduced: the stored position was not checked against the cells. An abort while the view was in the open message, and a wider terminal, gave an empty transcript. Fixed in the mechanism: `settle/1` after each event and each `Resize`, with the check that the scroll keys use.
- All agents: the branch was one merge behind `origin/master`. Rebased.

## Round 2 (full)

The fix added functions, so the round was full.

- Standards: no hard violation. `scroll/4` had a `case` on the key after a clause on the key. Now clauses. The rule moved to `hold/4`.
- Spec: a resize to a larger width left a row number past its cell, and each frame wrapped the cells that the row passed (2.5 ms against 0.3 ms). Fixed: `hold/4` moves the row into the cells that follow.
- Spec: exception 1 named a failed turn. The session closes the open message first, so only a client notice makes the case. Fixed in the row.
- Failure-path, reproduced: `settle/1` kept the position when the terminal gave no size, and the screen was empty. Fixed: nil.
- Failure-path, reproduced: a `/model` notice while the view is in the open message moves the view by the rows of the notice. Accepted as exception 1: the position has no identity. Accepted with no ticket for checkpoint one.

## Round 3 (full)

The fix was 16 lines added and 17 removed in one code file. More than 15 lines, so the round was full.

- Standards: the row said that a notice needs no check, and the comment of `hold/4` said that every position comes from it. Fixed: a `/model` line goes through `settle/1`.
- Standards: the words "ticket pending". Kept: the author of this change may not create issues.
- Spec: the cost of the one check after a resize was not in the row. Added, with the measurement of the agent: 4.9 ms for 3,450 cells, then 31 µs.
- Spec: the row did not say that the tests fold events through `Helyx.TUI`. Added.
- Failure-path, reproduced: with no terminal size a scroll key kept an old position, and ExRatatui drew the frame at 80 by 24. This was the second finding on the path with no size, so the mechanism changed: `on_screen/2` is the one reader of the size for the keys and for `settle/1`, and no size gives nil.

## Round 4 (full)

The fix removed `screen/1` and added `on_screen/2`, so the round was full.

- Standards and spec: two sentences in the right column of the row were from before the fix: the scroll keys with no size, and the `/model` line. Fixed in the row.
- Standards, judgement: the name `on_screen/2` and its parameter `position`. Not changed.
- Failure-path, reproduced only with a size that changes with no `Resize` event: a key that does not scroll does no check. ExRatatui sends a `Resize` for a size change, so the code is not changed. The row now states where the check runs.
- Spec and failure-path: random walks of 300 runs of 80 operations and of 4,000 steps kept the invariant.

The fix of round 4 is Markdown only, so there is no round 5.

## Outside the ticket

- A scroll position with an identity, so that a cell at the index of the open message does not move the view: accepted with no ticket for checkpoint one.
