# Review: ticket #40, the TUI wraps by display width

Date: 2026-09-19. Scope: `wrap/2` and the width rule in `Helyx.TUI` (`plugins/bundled/lib/helyx/tui.ex`), its tests, and `docs/features/coding-agent.md`.

## Invariant

No transcript row that `wrap/2` makes is wider than the transcript width in the columns that ExRatatui draws. A grapheme is never split. Entry point: `styled_lines/3`, the only caller of `wrap/2`. Every transcript line goes through it: user cells, assistant text and thinking, the tool call line, the tool result lines, the running line, the truncation line, and notices. The status line does not wrap and is not covered.

Documented exceptions:

1. A width less than 1 counts as 1.
2. A glyph wider than the full width gets a row of its own, and ExRatatui cuts it.
3. The width rule is a short list of ranges, not the Unicode tables. The test has every code point of five ranges in 13 contexts, not every sequence. The rule can count less for a sequence that no test has. Ticket pending: replace the rule with a width function of ExRatatui when it has one.

The rule can count more than ExRatatui draws. It has no rule for an emoji sequence, so an emoji with a skin tone modifier, a joiner sequence, or a flag counts each emoji in it. Such a row is shorter than it could be. Nothing is lost.

## Facts checked before the plan

- `:string.width/1` does not exist in OTP. `string:module_info(exports)` has no function that starts with `wid`.
- ExRatatui 0.14.1 has no width function in Elixir. Its `cell_session/cell.ex` tells the caller to compute the display width.
- `Paragraph` has `wrap: true`. It is not used: the transcript takes the last rows that fit, so the caller must have the row count, and #39 needs the rows as data.
- A probe in the ExRatatui test terminal showed that ExRatatui adds the code point widths of most graphemes, and draws the emoji sequences it knows as two columns.

## Bounds sensor

All rounds: `bounds sensor skipped: TYPESAFE_API_KEY is not set`

## Simplify

- Round 1 (4 agents): 5 applied. Ranges directly in `Enum.concat/1`; a comment on the ASCII fast path; `dup/2` deleted from the test; a fast path `byte_size(line) <= width`; a clause for code points below U+1100; a comprehension in place of two lists. Not applied: one generated clause for each wide symbol (more code, small gain). Reuse and altitude: clean.
- Round 2 (2 agents, four angles): 3 applied. `narrow_columns/1` renamed to `code_point_columns/1`; a comment on the first clause of the reduce; a range gate before the `@wide_symbols` scan. Not applied: `rest_columns/2` inline as an `if` (AGENTS.md prefers clauses); U+FE0F found in the same reduce (small gain).
- Round 3 (1 agent, four angles): 0 applied. Not applied: delete the ASCII fast path (it is the hot path). The exhaustive test, about 9 s in an async run, was judged acceptable.

## Round 1 (full)

- Standards, hard: the new `ponytail:` marker named no ticket. Fixed: `ticket pending`, because this run cannot create issues.
- Standards, judgement: the accumulator had the name of the function `columns/1`. Fixed by the later rewrite. Long sentences in the bounds row: fixed in round 3. An `if` in the reduce: accepted, a clause is not clearer.
- Spec and failure-path, the same defect, reproduced: the rule took the widest code point of a grapheme, and ExRatatui adds them. Thai `กำ`, Tamil `நி`, Devanagari `क्षि`, and halfwidth kana U+FF76 U+FF9E drew wider than counted, and ExRatatui cut the row. Fixed: the rule adds the code points.
- Spec and failure-path, reproduced: wide code points not in `wide?/1`: U+1F7E0 to U+1F7EB, U+2329, U+4DC0 to U+4DFF, U+1D300, and others. Fixed: the ranges were added, and a test now draws every code point. That test found U+17A4, U+17D8, and U+20F1 to U+20FF, fixed too.
- Spec: the doc did not list U+200E, U+200F, and the Hangul range as zero columns. Fixed.

Fix size: 1 code file, more than 15 lines, functions added. Round 2 is a full round.

## Round 2 (full)

- Standards: no hard violation. Judgement: the Khmer code points were not named in the doc, and the test ranges were not exact in the doc. Both fixed.
- Spec and failure-path, the same defect, reproduced: the emoji exception counted every later wide code point of a grapheme that starts with an emoji as zero. ExRatatui does that only for the sequences it knows. `⚡🏽`, `🟠🏽`, `🇮🏽`, `👍🏽🏽`, `👨` U+200D U+1FAFF, and others drew wider than counted.

This was the second finding on one mechanism, the guess of how ExRatatui joins a grapheme. The fix changed the mechanism, not the path: the emoji exception is gone. The rule is the plain sum, and a code point before U+FE0F is two columns or more. The cost is a shorter row for an emoji sequence. The test got 13 contexts, with starts and ends that make emoji sequences of each kind.

Fix size: 1 code file, more than 15 lines, functions removed and added. Round 3 is a full round.

## Round 3 (full)

- Standards: two sentences in the bounds row were too long. Split. `planes` in the test renamed to `ranges`. Two test names did not match their bodies: one renamed, one split. Not applied: a module `Helyx.TUI.Width` (the rule is small and has a planned end); the ranges are in the doc and in the code (the bounds table must stand alone); `if(wide?(code), ...)` as clauses.
- Spec: no path breaks the invariant. About 400,000 sampled sequences, 92 targeted sequences, and the old reproductions gave no cut row. Three small items, all fixed: the doc now says "an emoji that is wide by default"; the test now has the tag range U+E0000 to U+E0FFF; `count_z/1` counts by code point, because a prepended mark joins the next "z" into one grapheme.
- Failure-path: no finding. A sweep of every code point to U+10FFFF in 5 shapes, a cluster fuzz of 6000 samples, a mixed-line fuzz of 40000 lines at widths 1 to 12, and the byte fast path at `byte_size` and one under gave no violation. A line of 1,000,000 CJK glyphs wrapped in 283 ms in round 1.

The round 3 fixes changed only the test file and Markdown. The code diff of the fix is 0 lines, so no more round was necessary for them.

## Precommit, first run

Failed in the root project. Credo: `wide?/1` had a cyclomatic complexity of 25, and the limit is 9. The function was one chain of 25 `code in a..b or`. Fixed: the ranges moved to the module attribute `@wide_ranges`, and `wide?/1` read them with `Enum.any?/2`. This removed the range gate of simplify round 2; the clause `when code < 0x1100` stays the only gate.

Fix size: 1 code file, more than 15 lines. Round 4 is a full round.

## Round 4 (full)

- Simplify (1 agent, four angles), 1 applied: `code in` on a range that is not a literal goes through a protocol. A miss, for example the box-drawing U+2500, cost about 6.3 us, so a frame of 5000 such code points cost about 30 ms. Fixed: one generated guard clause for each range of `@wide_ranges`.
- Standards: no hard violation. The comment above `@wide_ranges` did not cover the three symbol ranges. Fixed. This record did not name the Credo fix. Fixed.
- Spec: all 4 acceptance boxes met. The ends of all 24 ranges count as expected, and a sweep of every code point to U+10FFFF in 5 contexts gave no cut row. A fuzz cut rows only at widths 1 and 2, where a prepended mark (U+0600, U+110BD, U+0D4E) joins the next letter into one grapheme wider than the width. That is exception 2.
- Failure-path: no finding. Range ends, a sweep of about 1.7 million rows, zero-width code points around 11 bases at 5 widths, and a fuzz of 3000 lines at each of 7 widths gave no cut row outside exception 2. Timing: 1,000,000 CJK glyphs at width 80 took about 400 ms with `Enum.any?/2`, against 283 ms in round 1.

Fix size: 1 code file, 7 lines, no function added or removed. Round 5 is a reduced round.

## Round 5 (reduced)

- Spec: no finding. A sweep from U+1100 to U+40100 showed that the wide set of the generated clauses is equal to `@wide_ranges` plus `@wide_symbols`. The ends of every range, drawn at widths 3 to 7, gave no cut row.
- Failure-path: no finding. Range ends, every code point to U+10FFFF in two shapes, nine suffix sequences, and a fuzz of 20,000 lines at each of 5 widths gave no cut row. Widths 0 and -3 and the empty line are correct. Timing at width 80, 1,000,000 glyphs: about 195 ms for `日`, about 235 ms for U+2500.

No code changed after round 5.

## Outside the ticket

- Ticket pending: a width function in ExRatatui (upstream, or a NIF call that the library adds) would replace the rule in `Helyx.TUI`. Until then an emoji sequence makes its row shorter than the width.
