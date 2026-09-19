# 2026-09-19: the status bar shows why input was rejected (#46)

## Done

- `Helyx.TUI.ViewModel` has a `reason` field. `reject/2` sets it and `clear_reason/1` clears it. No event changes it.
- A rejected steer or follow-up sets `not sent: the queue is full` or `not sent: not valid UTF-8`. The text stays in the composer.
- The status bar shows the reason in red as the first span. The next key press or paste clears it. There is no terminal bell.
- The reject of event text from #74 moved from a notice cell to the reason. The bounds row said that the notice was there only because the field did not exist. The count of notice cells had no limit; one field has.
- The review record is `docs/reviews/2026-09-19-ticket-46-status-bar-reason.md`.

## What broke

- The first version put the reason after the model span. The line does not wrap, so a long model ref hid the reason.
- The first version cleared the reason on a key repeat. The repeat of the rejected Enter then cleared the reason, and nothing was sent again.
- A test sent Alt+Enter against a full steer queue and expected a reject. The follow-up queue has its own cap.

## Next

- A rejected `/model` switch stays a notice cell. This is a decision, not a defect.
- Everything the ticket names exists: `Helyx.Session.steer/2`, `follow_up/2`, and both error atoms.
