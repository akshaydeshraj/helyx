# 2026-09-19: the cut edge alone decides what a cut loses (issue #68)

## Done

- `clean_edge/2` in `lib/helyx/tool.ex` no longer reads the whole cut. It
  takes the fewest bytes, 0 to 3, whose loss leaves a whole character at the
  cut edge; when no such loss exists, the edge loses 3 bytes.
- A line that ends in a partial character (`head -c`, a killed command) now
  gets a tail cut that starts on a character boundary.
- The test for an invalid byte away from the edge now asserts 51198 bytes,
  not 51197. Criterion 1 of the ticket requires this.
- The "tool result text" row of `docs/features/coding-agent.md` states the
  rule.
- Review record: `docs/reviews/2026-09-19-cut-edge-only.md`.

## What broke

- The first head edge rule used `:unicode.characters_to_binary/1`. Review
  round 2 found that it follows OTP for surrogate and overlong prefixes and
  that a stray byte after a whole character lost the character. Round 3
  replaced the mechanism.
- The first version of the new invalid-edge test put the invalid
  bytes at the far end, not at the cut edge; corrected before the code.

## Next

- `drop_continuation/2` in the bash tool is a second copy of the tail rule.
  One helper needs a public function in `Helyx.Tool`; that is a decision for
  a ticket.
