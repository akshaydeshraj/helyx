# Review: cap of the Codex held events (#111)

Base: `origin/master` at `561a67b`. Round 1 is the first and complete round. Round 2 is a reduced rerun round for the fix of round 1.

## Change

`Helyx.Provider.Codex` holds at most 10,000 events (`@held_max`). `order_one/2` checks the count before each event is held. It is the only place that adds to `held`. At the cap, the event over the cap and the rest of its line are dropped, and the terminal is `{:error, {:held_over_limit, 10_000}}`. `settle/1` then sends the events of the chunk and the held events, in order, as at every other terminal. No later line is read, and the closed port ends the program.

Invariant: at the entry point `Codex.stream/3`, the program's stdout lines (the boundary) go through `Helyx.HarnessIO.lines/3` and `in_order/2`, and the held queue never has more than 10,000 events; at the cap, the stream sends the held events and then ends with one error.

Doc rows of the same ticket:

- `docs/features/coding-agent.md`: the row "Codex held events" states the cap. The row "Harness tool calls and messages per harness turn" is accepted: the program's own loop sets the number, and the user's abort bounds it, as for model turns.
- #101: the row "handles per Task" in `docs/features/tool-resource-release.md`.
- #106: the rows "SSE line from the model gateway" and "Tool call bytes per response" state that their byte caps bound the JSON decode, with no heap cap.
- #112: `docs/features/external-turn.md`, section "Known gap".

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents. Reuse, efficiency, and altitude: no findings.

- Skipped: use `Enum.reduce_while/3` in `in_order/2` in place of the first `order_one/2` clause. Each branch then needs a `{:cont, _}` wrapper, so the change adds code.

### Standards

- Fixed: the checklist asks for a test one under the limit. Test "the held events one under the cap go out at the turn's end".
- Not changed: the long sentences of the feature doc rows. They follow the style of the file.

### Spec

- Fixed: the ticket text for #101 said "2 per Task". Claude Code starts a second run in the same Task after a lost session (`exited/2` and `exit_timeout/1` with the terminal `:lost`), so its Task holds at most 4 handles. The row says 2 per run and at most 4 per Claude Code Task.
- Fixed: the ticket example for #112 said that a Codex held result shows as `aborted`. On an abort, `abort_turn/3` gives `aborted` only to the open calls in the transcript, and the partial message is not added. The call of a held result is in a held message, so it never reaches the transcript. The section names a result of a sent call that is still in the pipe as the example, and states the held case separately.

### Failure path

- Fixed in the doc: the cap counts events, not bytes. Each held event is within the 16 MiB line cap, so the held events can use up to 10,000 × 16 MiB. Reproduced: 40 held deltas of 8 MiB gave a peak of 328 MiB in the stream Task. The row states this. The held events are the events that the session appends to the transcript when they go out, and the owner accepted that volume per turn, bounded by the user's abort. A byte cap is a new decision for the owner.
- Checked with no finding: 4,990 held call and result pairs end with the error after 864 ms, within the 2,000 ms shutdown grace. A waiting result goes out before the count check. A port exit in the same mailbox keeps the first terminal.

## Round 2

Reduced round: the fix changed 0 code lines (tests and Markdown only). Base: the round 1 state.

### Spec

No findings. All three fixes match the code.

- Fixed: the comment above `settle/1` now names the held cap in its list of terminals.

### Failure path

The round 1 doc fix holds. No event reaches `held` without the count check, no terminal is overwritten, a waiting result is not dropped, and the stream ends after the cap (checked through a real session; the OS process was dead).

- Fixed in the doc: the cap drops the rest of its line, not only the one event. Reproduced: with 9,999 held events, one `item/completed` line of a call with no start gives a call, a `message_end`, and a result; the call is held event 10,000, and the other two are dropped, so the transcript does not have the call. The row states this and points to "Known gap" of `docs/features/external-turn.md`.

The round 2 fixes change only a comment and Markdown, so no further round is needed.
