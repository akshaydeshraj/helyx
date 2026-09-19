# Review: ticket #74, a TUI insert of invalid UTF-8 raises

Date: 2026-09-19. Branch `ticket/74-tui-invalid-utf8`, base `origin/master` at `0d64a3b`. The reviews ran on the same change on top of `d785796`; `origin/master` moved during the round, and the change applied to `0d64a3b` with no conflict.

Invariant: event text that is not a valid UTF-8 binary never reaches the input widget of `Helyx.TUI`. The private function `edit/3` is the only path from event text (a key code, a paste) to the widget. It rejects the full text, leaves the composer unchanged, adds one notice cell, and does not raise.

Documented exceptions:

- `text_input_set_value/2` does not go through `edit/3`. It gets only the literal `""`.
- The status bar reason field of #46 does not exist. The reject shows as a notice cell.
- The count of notice cells from rejected events has no limit. Accepted: no known source sends such text.
- The invariant covers text only. A `%Key{}` with `modifiers: nil` raises in the generic key clause (`key.modifiers -- ["shift"]`). This is older than #74, and ExRatatui always gives a list. Ticket pending.

Probe before the change: `text_input_insert_str/2` and `text_input_handle_key/2` both raise `ArgumentError` on `<<0xFF>>`. The ticket names only the first.

## Simplify

Four agents: reuse, simplification, efficiency, altitude. Reuse, efficiency, and altitude reported clean.

- Reuse, not applied: `Helyx.Message.valid_utf8?/1` is true for a term that is not a binary, so it does not fit this guard.
- Simplification, not applied: one `{:noreply, ...}` around the `if`, and `is_binary/1` as a guard clause. Each form has the same size and the same behaviour as the current one.

## Round 1, complete round

Bounds sensor, base `origin/master`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Standards: 0 hard violations, 4 judgement calls.
  - Applied: the doc row now uses active verbs.
  - Applied: the doc row now names the `is_binary/1` check, so the doc and the code state the same rule.
  - Not applied: rename `edit/3`. The comment above it states its purpose, and the two callers read well.
  - Not applied: a private `notice/2` for the three `%{state | vm: ViewModel.notice(...)}` sites. Two of them are older than this change.
- Spec: 1 partial, 2 scope notes, 0 wrong.
  - Partial: the test has no `Process.alive?` assertion. Each test in the file calls the callbacks directly, so the test process is the TUI process. A raise fails the test; the `{:noreply, state}` match is the evidence. Not changed.
  - Scope: the guard also covers `text_input_handle_key/2`. Kept: the probe shows the same raise, and one function covers both.
  - Scope: a notice cell. Kept: a silent reject hides the cause from the user, and `ViewModel.notice/2` exists.
  - Applied: the doc row now says that each rejected event adds one cell and that the count has no limit.
- Failure path: 34 throwaway cases, 0 defects in the change.
  - Held: a lone surrogate, an overlong form, a truncated sequence, U+110000, `nil`, an integer, a charlist, a list, an atom. Accepted as valid: U+10FFFF, a ZWJ emoji, a BOM, `""`, 10 MB of multibyte text, NUL.
  - Outside the change: `modifiers: nil` raises. See the exceptions. Ticket pending.

The fixes of this round changed only Markdown, so no rerun round was necessary.
