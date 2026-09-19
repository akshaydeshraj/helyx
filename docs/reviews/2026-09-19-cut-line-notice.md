# Review: the truncation notice names a cut line (issue #50)

Scope: `lib/helyx/tool.ex`, `test/helyx/tool_test.exs`,
`plugins/bundled/test/helyx/tool/read_test.exs`, and the "tool result text"
row of `docs/features/coding-agent.md`.

Invariant: a truncation notice never presents a line as whole when
`Helyx.Tool` cut it. The notice names the cut line by its absolute number
and the bytes the tool kept (`, line N cut at B bytes`). A notice for a
result truncated on whole lines does not change. The cut itself stays
(triage).

Bounds sensor, both rounds, as printed:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (full: simplify, standards, spec, failure-path)

Simplify: reuse, efficiency, and altitude reported clean. Simplification
had two findings.

1. **Duplicate assertion in the new unit test (simplification).** Fixed:
   the new test keeps the `TAIL_MARKER` check, the offset case, the
   one-over case, and the multibyte case.
2. **The read tool test repeats the unit test (simplification, also
   standards).** Not applied: the issue's reproduction is a file read, and
   the acceptance criteria ask for a test of the reproduction.

Standards: no hard violation, judgement calls only.

3. **`cut` named both a byte count and the function `cut/2`.** Fixed:
   `cut_bytes`, and `line_number` in `cut_note/2`.
4. **Callers must know that the cut line is the kept edge.** Fixed: a
   comment on `cut_note/2` states it.
5. **Third tuple element is `nil | bytes` (weak Primitive Obsession).**
   Not applied: a private helper, and a separate shape adds a clause at
   both call sites.

Spec: all three acceptance criteria held. Four gaps.

6. **The property test made the note optional and checked nothing of
   it.** Fixed: `notice/2` captures the note; the property asserts that it
   is there exactly when the line was cut, with the line number and
   `byte_size(content)`.
7. **No test one byte over the cap.** Fixed: 51201 bytes, `:head` and
   `:tail`. At the cap and one under are covered by "a line exactly at the
   byte limit is kept" and the property.
8. **The doc row recorded unreachable bytes against the ticket this
   change closes.** Fixed: the row says the cut is an accepted ceiling
   (#50 triage).
9. **No research citation.** Fixed: the row cites opencode's read in
   `docs/research/coding-tools.md`.

Failure-path: three reproduced findings.

10. **B is not the delivered size for invalid bytes.** Bash output of
    60,000 `0xFF` bytes gives `cut at 51197 bytes`; the hands then replace
    each byte with U+FFFD. Resolved in the doc: B counts the tool's own
    text, and the row points at the validity row for the growth. The
    notice is built before the hands run, so the tool cannot know more.
11. **A cut last line still says `read again with offset N+1`, and that
    read is empty.** Older than this diff and asserted by an existing
    test. Not changed: the triage says only the cut note is added. Left
    for the orchestrator as a possible follow-up ticket.
12. **An over-cap line that is not at the kept edge is dropped whole, and
    the first doc wording called that a cut.** Fixed in the `@doc` and the
    doc row: the rule is for the line at the kept edge. A dropped line is
    never shown, so the notice cannot present it as whole.

The wording "cut at B bytes" does not say which end a tail keeps. Not
changed: the triage asks for the line and the bytes.

## Round 2 (reduced: spec, failure-path)

The fix, without tests and Markdown: 8 lines in one file, `lib/helyx/tool.ex`
(a rename, one comment, the `@doc` wording). No function, arity, or spec
change. Reduced round.

Spec: no missing requirement, no scope creep, two doc statements wrong.

1. **"That ceiling is accepted" read as the 3x growth, and "in the same
   way" said more than the research.** Fixed: the acceptance is tied to
   the cut, and the row says opencode "also marks a cut line".
2. **Bash line numbers count from the kept buffer, not from the whole
   output.** Older than this diff; the new note inherits it. Fixed in the
   row: it now says so and points at the buffer row.

Failure-path: no second path breaks the invariant. Cells run: a cut line
in an offset window, a tail with a trailing newline, multibyte at the cut
for both ends, a line exactly at the cap, an over-cap line off the kept
edge, CRLF. `keep_tail` in bash is a second cut site, but a partial line
it leaves is shown only when it is over the cap, so it gets the note. The
agent reproduced finding 11 of round 1 again; same resolution.

The round 2 fixes are Markdown only, so no further round.
