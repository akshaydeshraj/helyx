# Review: the cut edge alone decides what a cut loses (issue #68)

Scope: `clean_edge/2`, `edge_bytes/2`, and `continuation_bytes/2` in
`lib/helyx/tool.ex`, `test/helyx/tool_test.exs`, and the "tool result text"
row of `docs/features/coding-agent.md`.

Invariant: what the cut of an over-long line loses depends only on the bytes
at the cut edge. The cut loses the fewest bytes, 0 to 3, that leave a whole
character at the edge; when no such loss exists, the edge was never valid
and loses 3. The shown line is an exact prefix or suffix of the input, and
the notice `line N cut at B bytes` states the bytes the tool returns.

Bounds sensor, all three rounds, as printed:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Design notes

- The #51 rule compared `String.replace_invalid/2` over the whole cut with
  the cut less its edge bytes, so one invalid byte anywhere made the line
  "never valid". The new rule reads at most 4 bytes at the edge.
- `clean_edge/2` tries a loss of 0, 1, 2, and 3 bytes and takes the first
  that leaves a whole character at the edge (`whole_edge?/2`). One rule covers
  both edges, a cut inside a character, a prefix that no valid character has,
  and up to 3 invalid bytes that stand at the edge. Rounds 1 and 2 reviewed
  an earlier rule that judged parts of a character; round 2 stopped it.
- The test "an invalid byte away from the cut edge is kept for the hands to
  replace" asserted 51197 bytes under the whole-line rule. Criterion 1 of the
  ticket removes that rule, so the test now asserts 51198: the two bytes of
  the cut "€". Criterion 4 covers the test "a cut on text that was never
  valid", which is unchanged.
- `drop_continuation/2` in the bash tool still holds the tail rule a second
  time. A shared helper is a new public function of `Helyx.Tool`, which is
  out of scope (see the #51 record, finding 6).

## Round 1 (full: simplify, standards, spec, failure-path)

Simplify: reuse, efficiency, and altitude clean. Simplification 2, both
fixed.

1. **`edge_bytes/2` for the head edge scanned the edge two times with two
   closures and a `cond`.** Fixed: one `Enum.find_value/3` with a `case`.
2. **`continuation_bytes/2` counted to 4 and needed a second guard.** Fixed:
   the first clause stops under `@max_partial_bytes`.

Standards: no hard violation. Judgement calls 4, two applied.

3. **Bare `4` in `edge_bytes/2`.** Fixed: `@max_partial_bytes + 1`.
4. **No test for continuation bytes before a byte that starts no
   character.** Fixed: `<<0x80, 255>>` on the tail edge.
5. **The two `edge_bytes/2` clauses use different methods.** Not applied: a
   tail edge has no lead byte for `:unicode` to judge.
6. **The `:tail` clause only delegates.** Not applied: it keeps the dispatch
   on `keep` in one place and holds the comment.

Spec: the four acceptance criteria hold; the changed assertion agrees with
criterion 1. Partial gaps, fixed in tests only:

7. **No test for stray continuation bytes on a tail cut, which the doc row
   states.** Fixed: a test for 1 to 3 of them.
8. **The head edge had no case with four continuation bytes.** Fixed.

Failure-path: no defect. Valid text of 1 to 4 byte characters at every
offset, lines at 51,199, 51,200, and 51,201 bytes, adversarial edge bytes,
and a fuzz of 200 binaries held the invariant. One doc mismatch:

9. **The doc said "a byte that no character holds" loses 3 bytes, but a head
   edge that ends in `0xC0`, `0xC1`, or `0xF5` loses 1**, because
   `:unicode.characters_to_binary/1` calls it incomplete. Fixed in the doc:
   the loss is inside the bound and the hands replace the byte.

## Round 2 (reduced: spec, failure-path)

Fix counted without tests and Markdown: 2 lines, one file, no function
added. Reduced round.

Spec: criteria hold. Two findings, both on the head edge rule.

1. **A stray continuation byte after a whole "€" on a head edge lost 3 bytes
   and left a lone `0xE2`**, where master lost 1. The tail edge handled the
   mirror case.
2. **The doc named `0xC0`, `0xC1`, `0xF5` with no test, and incomplete pairs
   followed OTP, not a stated rule.**

Failure-path: one finding, reproduced with 83,521 edges against an oracle.

3. **Head edges `0xED 0xA0`, `0xE0 0x80`, `0xF4 0x90`, `0xF0 0x80` lost 2
   bytes where the stated rule gave 3**:
   `Tool.truncate(String.duplicate("a", 51_198) <> <<0xED, 0xA0>> <> "zzzz", :head)`.
   `:unicode.characters_to_binary/1` calls these incomplete.

Findings 1 to 3 and round 1 finding 9 are one mechanism, the head edge judged
through `:unicode`. Two findings on one mechanism stop the patching: round 3
replaces the mechanism.

## Round 3 (full: simplify, standards, spec, failure-path)

Fix counted without tests and Markdown: over 15 lines, functions added and
removed. Full round. Deviation: the reuse and the efficiency angle of
simplify ran in one agent.

The first fix judged a head edge by the shape of its bytes (`lead_bytes/1`).
Simplify: reuse, efficiency, simplification clean (one optional test helper,
not applied). Altitude 1:

1. **Two hand-written byte shape parsers, one per edge, only to make an
   invalid edge lose 3 bytes.** Fixed: the fewest-bytes rule above. It
   removes `edge_bytes/2`, `lead_bytes/1`, and `continuation_bytes/2`, and
   finding 1 of round 2 now loses 1 byte as on master. Two tests new in this
   branch changed their expectation; no test of master changed.

Standards, spec, and failure-path then reviewed the fewest-bytes rule.

Standards: no hard violation. Judgement calls, not applied: the default
argument of `Enum.find/3` reads like a bound (the comment explains it), the
two `whole_edge?/2` clauses differ (no suffix match for `::utf8` exists),
repeated test setup, a long doc cell.

Spec: no break; doc, tests, and code agree; 6000 random cases against a
model, 0 mismatches.

2. **No test with invalid bytes away from the edge and a loss of 0.** Fixed,
   test only.
3. **The comment at `take_within_limits/2` says "on a character boundary",
   which is false for an edge that was never valid.** Not applied: older
   than this diff, and the #51 record states the exception.

Failure-path: no findings. All 234,256 edges of 4 bytes from 22
representative bytes, and 60,000 random 8-byte edges with invalid fill and
lines before and after, on both edges, against an oracle: 0 mismatches.

No code changed after round 3.
