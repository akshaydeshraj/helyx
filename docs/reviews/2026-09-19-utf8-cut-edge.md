# Review: UTF-8 cut edges in `Helyx.Tool` and the bash tool (issue #51)

Scope: `lib/helyx/tool.ex`, `plugins/bundled/lib/helyx/tool/bash.ex`, their
tests, and the "bash output buffer" row of `docs/features/coding-agent.md`.

Invariant: a byte cut in text that was valid UTF-8 gives valid UTF-8, an
exact prefix or suffix of the input less at most one character; the notice
`line N cut at B bytes` states the bytes the tool returns; `keep_tail/1`
never touches the end of the buffer, which the next chunk can complete.

Bounds sensor, both rounds, as printed:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Design notes the ticket asked to report

- `String.replace_invalid/2` over the whole cut changes the result the test
  "a cut on text that was never valid" asserts (51197 bytes of `0xFF`
  kept). The ticket says to keep the asserted behaviour. `clean_edge/2`
  takes the `replace_invalid` result only when the removed bytes are at most
  three and all at the cut edge; any other text was never valid and loses
  three bytes at the edge, as before. `on_boundary/3` and `drop_edge/2` are
  gone.
- The bash site does not use `String.replace_invalid/2`. It cannot clean the
  whole buffer, because the end of `acc` can hold a character that the next
  chunk completes, and a window of edge bytes has no aligned end. The start
  of the tail can only hold continuation bytes of the cut character, so
  `drop_continuation/2` drops at most three of them.
- The run path cannot observe the start of the kept tail: 204,800 bytes are
  always over a limit of `truncate/2`, which drops the first line or cuts it
  again. `keep_tail/1` is thus public with `@doc false` for a direct test,
  as `launcher/1` is.

## Round 1 (full: simplify, standards, spec, failure-path)

Simplify: reuse and efficiency clean. Simplification 4, altitude 2.

1. **`cond` on `keep` in `clean_edge/2` (simplification).** Fixed: function
   clauses in `without_edge/3`.
2. **`keep_tail/1` public for one test (simplification, altitude, spec).**
   Not applied: see the design notes.
3. **The new unit test computed its expectation as the code does
   (simplification).** Fixed: literal expected lines.
4. **Test copies the `@keep_bytes` formula (simplification).** Not applied:
   follows from 2.
5. **`clean_edge/2` deleted up to three invalid bytes anywhere in the line,
   a policy by byte count (altitude).** Fixed: the clean text is taken only
   when it equals the cut less its edge bytes; the test now asserts that an
   invalid byte away from the edge is kept for the hands.
6. **Two edge algorithms, one per project (altitude, standards Duplicated
   Code).** Not applied: one shared helper is a new public function of
   `Helyx.Tool`, an interface change outside the ticket. Reported.

Standards: no hard violation. Judgement calls: 6 above, and

7. **Bare `3` in `bash.ex`.** Fixed: `@max_continuation_bytes`.
8. **`keep` names the side that stays in `without_edge/3`.** Not applied:
   the name was there before and `cut/2` uses it the same way.

Spec: the three acceptance criteria hold. Findings:

9. **Feature doc row "bash output buffer" said the fragment becomes
   U+FFFD.** Fixed.
10. **The ticket body asks for `replace_invalid` at both sites.** Not
    applied: see the design notes; the triage criteria ask for it in
    `Helyx.Tool` only.
11. **The kept-behaviour report was missing.** Fixed: this record.
12. **No `keep_tail/1` test at exactly twice the cap.** Fixed.

Failure-path: one finding, reproduced, older than this diff.

13. **A valid line that ends inside a character (`head -c`, a killed
    command) counts as never valid, so a `:tail` cut can start inside a
    character**: `Tool.truncate(String.duplicate("😀", 20_000) <> <<0xF0,
    0x9F>>, :tail)`. `on_boundary/3` did the same. Not applied: the ticket
    covers text that was valid before the cut, and the hands replace the
    bytes. Reported to the orchestrator.

## Round 2 (reduced: spec, failure-path)

Fix counted without tests and Markdown: 4 lines, one file
(`bash.ex`, the named constant), no function added. Reduced round.

Spec: nothing wrong, three partial gaps, fixed in tests and Markdown only.

1. **No test over `@max_continuation_bytes` and none one byte under twice
   the cap.** Fixed.
2. **The doc row did not state the never-valid case.** Fixed.
3. **`[output cut: only the last 204800 bytes were kept]` can be up to three
   bytes high.** Not applied: the number was never exact (the buffer holds
   up to twice the cap) and the #50 rule names the line notice. The doc row
   now states 204,797 to 204,800.

Failure-path: no findings. Fuzz of `truncate/2` on both edges and of the
`collect/3` fold over `keep_tail/1` with chunk ends inside characters held
the invariant.
