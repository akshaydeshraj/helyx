# 2026-09-25: multiline composer (#44)

## Done

- The TUI composer is an `ExRatatui.Widgets.Textarea`. Enter sends, Alt+Enter queues a follow-up, Ctrl+J adds a new line, and Shift+Enter adds one where the terminal reports Shift on Enter.
- A paste keeps its new lines and tabs. A paste of more than 5 lines is one marker, `[Pasted text #1, 20 lines]`, and is sent in full. A marker is one unit for every edit, and only the markers that the composer made are replaced on send.
- The composer grows to 8 lines. One rule, `composer_rows/1`, sets its height for the render and for the scroll screen.
- Feature doc: `docs/features/multiline-composer.md`. Review: `docs/reviews/2026-09-25-ticket-44-multiline-composer.md`.

## What broke

- A repeat of Enter went to the textarea and added a line. Enter now never reaches the widget.
- A typing key that changed the composer height did not check the scroll position. `edit/3` now runs `settle/1` when the height changes.
- The Right key of the textarea stops short of zero-width characters at the end of a line, so Right keys could not reach the end of a marker. The TUI now sets the text after the cursor and inserts the text before it, which puts the cursor exactly at the marker edge.

## Next

- The kitty keyboard protocol for Shift+Enter: #108. ExRatatui 0.14.1 has no call to push keyboard enhancement flags.
