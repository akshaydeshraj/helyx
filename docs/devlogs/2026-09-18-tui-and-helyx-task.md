# 2026-09-18: TUI and the helyx Mix task

Issues #5 and #9. Issue #9 was blocked by #5, which was still open, so #5 shipped first in its own commit.

## Done

- `Helyx.Session` steer and follow-up queues (#5): `steer/2`, `follow_up/2`, `queue_count/1`, and the `queue_update` event. Steers join the transcript before the next provider call inside the turn; follow-ups and leftovers start one new turn after a normal end; abort and failure drop both queues. The drain event goes out between turns with a nil turn id.
- `plugins/tui`: `Helyx.TUI` on ex_ratatui 0.14 (callback runtime, precompiled NIF, no Rust toolchain needed) and `Helyx.TUI.ViewModel`, a pure fold over `Helyx.Event` tested with scripted event lists. Transcript with streaming text, dim thinking, tool cells with four-line results, notices for aborted and failed turns; composer; status bar with model, run state, and queue counts.
- `apps/coding_agent`: the product. `CodingAgent.run/1` wires Core, the bundled plugins, one session, and the TUI. `mix helyx [directory] [--model provider/model]`, default `opencode-go/kimi-k2`, `fake/echo` for a key-less run.
- Root `mix precommit` now covers `plugins/tui` and `apps/coding_agent`; Credo includes `apps/`.

## Decisions

- No Transport interface yet. The ticket says events arrive "through the local Transport, which is OTP messages in one node" — that is exactly `Helyx.Session.subscribe/1`, so a Transport behaviour with one pass-through implementation would add nothing. It arrives with the first remote client. The TUI is a client, not a Core plugin: it implements no interface and never enters Core's plugin list, so it is `Helyx.TUI`, not `Helyx.<Interface>.<Name>`.
- Alt+Enter is the follow-up modifier. Without the kitty keyboard protocol (which ex_ratatui does not enable) most terminals send plain `\r` for Shift+Enter.
- Enter always sends a steer; the session turns an idle steer into a prompt, so the TUI cannot race the end of a turn.
- Escape aborts from a `Task.start/1` so the render loop never blocks on OS-process cleanup.

## Broke

- The Elixir 1.19 type checker rejects `Map.update!(state, key, ...)` on a struct with a dynamic key and infers over-tight domains through pipelines that set and then use `state.turn`; both needed explicit clauses.
- The first pty smoke test ran during compilation and typed into nothing; the second had a 0x0 pty from `script` until an explicit `stty rows 24 cols 80`.

## Verified

- Headless pty run of `mix helyx --model fake/echo`: enters the alternate screen, renders the typed prompt into the transcript through a real turn, and restores the terminal on Ctrl+C (`?1049h` … `?1049l` captured once each).

## Next

- The last #9 acceptance box — a multi-step session against OpenCode from this repository — needs `OPENCODE_API_KEY` and a human at the terminal; it was not runnable here.
- Ticket #29: bound the queues (and the composer shares its vocabulary).
- Ticket #39: transcript scrollback. Ticket #40: wrap by display width, not grapheme count.

## Review

- Four rounds; findings and resolutions in `docs/reviews/2026-09-18-tui-and-helyx-task.md`.
- Notable fixes: `Helyx.TUI.run/1` surfaces abnormal exits as `{:error, reason}`; the TUI monitors its session (new `Helyx.Session.pid/1`) and exits on session death instead of hanging or crashing on the next keypress; the view model fold is total — every clause head matches key and value shape; tool-result truncation ignores trailing newlines; `mix helyx` validates its arguments before `app.start`.
- New tickets: #39 (transcript scrollback), #40 (wrap by display width); both named by their `ponytail:` markers.
