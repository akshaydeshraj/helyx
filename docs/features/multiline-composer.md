# Multiline composer

## Goal

The TUI composer holds more than one line, so a user can write and paste code (#44). The decision on the ticket, 2026-09-25:

- Enter sends, as before. Alt+Enter stays the follow-up key.
- Ctrl+J adds a new line in every terminal. In raw mode crossterm reports the LF byte as `j` with `ctrl`, so ExRatatui gives the key code `"j"` with the modifiers `["ctrl"]`.
- Shift+Enter adds a new line where the terminal reports Shift on Enter. Elsewhere Shift+Enter is Enter and sends.
- A paste keeps its new lines and tabs. A paste of more than 5 lines shows in the composer as one marker, `[Pasted text #1, 20 lines]`, like Claude Code and Codex. The full text is sent with the prompt, so the session saves it in the transcript. Backspace on a marker, with the cursor inside it or right after it, removes the whole marker. A paste of 5 lines or fewer shows as normal text. The Tab key goes to the textarea, which indents; the one-line input ignored it.

The kitty keyboard protocol is not on. ExRatatui 0.14.1 has no option to push keyboard enhancement flags: `native/ex_ratatui/src/terminal.rs` turns on the alternate screen, bracketed paste, and optional focus and mouse reports, and nothing else. Turning it on needs a change to ExRatatui (a fork or an upstream change), which is undecided. Until then, Shift+Enter adds a new line only in a terminal that reports Shift on Enter without the protocol.

## Interface changes

No public function changes. The state of `Helyx.TUI` changes:

- `input` is an `ExRatatui.textarea_new/0` reference, drawn as `ExRatatui.Widgets.Textarea`, in place of the one-line `TextInput`.
- `pastes` maps each marker text to the full paste it stands for.

The status bar key help adds ` · Ctrl+J newline`.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| Composer height | At most 8 lines inside the two borders, so 3 to 10 rows. On a small terminal the composer shrinks, down to 3 rows, so the transcript keeps 1 row: the terminal height minus 2, and not less than 3. `composer_rows/2` is the one rule. The render (`Layout.split/3`) and the scroll screen (`on_screen/2`) both read it with the height they have, so the transcript screen that the scroll position is checked against is the screen that is drawn. An edit that changes the line count runs `settle/1`. At 4 rows or less the transcript has no row, and the scroll screen is 1 row: exception 3 of the scrollback row of `coding-agent.md`, as before | The textarea scrolls to its cursor. A line longer than the composer width scrolls sideways, as the one-line input did |
| Composer text | Unbounded human input, as before (#29) | Nothing is cut |
| Paste line count | More than 5 lines is a marker. A line ends at a new line, and a final new line does not start a line: `"a\nb\n"` is 2 lines. CRLF and a lone CR count as one new line each | The paste shows as the marker, and the full text goes in `pastes` |
| Paste text | Valid UTF-8, checked by `edit/3` as for every event text. CRLF and a lone CR become LF. Control characters other than tab and LF drop, the same set the transcript drops, so no escape sequence reaches the terminal through the composer. Size is unbounded human input (#29) | Invalid UTF-8 is rejected with the reason `input rejected: not valid UTF-8`, and the composer does not change |
| `pastes` map | One entry for each paste of more than 5 lines since the last send or `/model` switch. An entry stays after its marker is deleted. The map empties when a send or a `/model` switch empties the composer, so the marker ids start at `#1` again | A rejected send keeps the map with the text |
| Backspace on a marker | With pastes pending, one Backspace reads the composer text once (`textarea_get_value/1`) and searches the cursor line for each pending marker. The cursor column counts code points; one pass over the line turns it into a byte offset, and the matches compare bytes, so the cost is linear in the line for each marker. A line of many copies of a marker costs no more than one pass for each marker. With the cursor inside a marker or right after it, it moves the cursor to the end of the marker with Right keys, then sends one Backspace to the widget for each character of the marker: 23 characters plus the digits of the id and the line count | With no pending paste, Backspace goes to the widget as before |
| Send | The composer text with each marker replaced by its paste, in one pass (`String.replace/3` with the list of markers), so a marker inside a paste is not replaced again. The `/model` rule reads this text | |

Accepted holes:

- A marker is plain text in the widget. Text the user types or pastes that is equal to a pending marker is also replaced on send. Text that differs from a marker by one character, for example after a Delete inside it, is sent as it is, and that paste is not sent.
- The same match on text applies to Backspace: Backspace on typed text equal to a pending marker removes all of it.
- Delete, or a typed character inside a marker, changes one character, and the marker then no longer stands for its paste.
- The repeat and the release of Enter do nothing. Holding Enter does not add lines.

## Ownership

No external resource. The textarea state is a NIF resource owned by the TUI process, freed with it.

## Out of scope

- The kitty keyboard protocol: needs an ExRatatui change, undecided (#44).
- Undo and the Emacs keys of the textarea: keys with Ctrl or Alt do not reach the widget, as before.
- A limit on the composer text: unbounded human input (#29).
