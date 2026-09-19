# Ticket #39: TUI transcript scrollback

Date: 2026-09-19.

## Done

- PgUp and PgDn scroll the transcript by one screen. Ctrl+End, a PgDn at the end, or a sent prompt returns to the newest output. The status bar says `scrolled`.
- The position is client state of `Helyx.TUI`: nil, or a cell index and a row. New output does not move it.
- No line cache. A wrap of all cells is 90 ms for 1,000 cells and 2.2 s for 10,000, and a frame runs for each event. So no operation wraps all cells: a frame and a key wrap the cells near the screen. A scrolled frame with 10,000 cells is 0.3 ms.
- The key codes of ExRatatui are `page_up` and `page_down`.

## What broke

- The first version did not check the stored position against the cells. An abort in the open message and a wider terminal gave an empty screen. `settle/1` and `hold/4` now hold one invariant.
- The path with no terminal size had two findings. One function, `on_screen/2`, now reads the size.
- Review record: `docs/reviews/2026-09-19-ticket-39-scrollback.md`.

## Next

- A position with an identity: accepted with no ticket for checkpoint one.
