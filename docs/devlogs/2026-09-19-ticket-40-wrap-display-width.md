# Ticket #40: the TUI wraps by display width

Date: 2026-09-19.

## Done

- `wrap/2` in `Helyx.TUI` now fills a row by terminal columns, not by grapheme count. It stays one pure function from a line and a width to rows, so #39 (scrollback) can build on it.
- The width rule is a short list of ranges in `Helyx.TUI`. `:string.width/1` does not exist in OTP, and ExRatatui has no width function in Elixir. `Paragraph` has `wrap: true`, but the transcript needs the row count in Elixir.
- A test draws every code point of five ranges in 13 contexts in the ExRatatui test terminal and checks that no row is cut. The terminal library is the oracle, so the rule and the draw agree.
- The bounds table in `docs/features/coding-agent.md` has a new row, "Transcript row width".

## What broke

- The first rule took the widest code point of a grapheme. ExRatatui adds them, so Indic and Thai clusters were cut. Review round 1 found it.
- The second rule had an exception for emoji sequences. It was a guess of what ExRatatui joins, and review round 2 broke it with `⚡🏽`. The exception is gone: the rule is a plain sum. An emoji sequence now makes its row shorter than the width, and nothing is cut.
- The exhaustive test found code points that no review had: U+17A4 is two columns, U+17D8 is three, and U+20F1 to U+20FF are not zero.

- The first precommit run failed on Credo: `wide?/1` was one chain of 25 range checks. The ranges moved to `@wide_ranges`. A read of them with `Enum.any?/2` was slow, about 6 us for each miss, so the clauses of `wide?/1` are now generated from the attribute at compile time.

## Next

- Ticket pending: replace the rule with a width function of ExRatatui when it has one.
- #39 (scrollback) builds on `wrap/2`.

Review record: `docs/reviews/2026-09-19-ticket-40-wrap-display-width.md`.
