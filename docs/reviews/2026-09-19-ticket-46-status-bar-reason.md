# 2026-09-19: review of the status bar reason (#46)

Scope: `plugins/bundled/lib/helyx/tui.ex`, `plugins/bundled/lib/helyx/tui/view_model.ex`, their tests, and `docs/features/coding-agent.md`. The base of each round is `origin/master`, because the change has one commit.

## Invariant

While a reason is set, the status bar shows it in full, only a new key press or a paste clears it, and a new reject replaces it. The entry points are `Helyx.TUI.handle_event/2` (the clear, and the two rejects in `send_message/3` and `edit/3`) and `status_widget/1` (the render). Documented exceptions: a terminal of fewer than 35 columns cuts the reason, a frame of height 1 has no status row, and a rejected `/model` switch stays a notice cell.

## Bounds sensor

All rounds: `bounds sensor skipped: TYPESAFE_API_KEY is not set`

## Round 1 (full)

Simplify, four agents: reuse, efficiency, and altitude were clean. Two findings applied:

- Simplification: `status_widget/1` built the span list on three levels of nesting. Fixed: two bound spans and one list.
- Altitude: the literal `["press", "repeat"]` stood in two places. Fixed with a module attribute. Round 1 of the review removed the second use, so the attribute went away again.

Skipped: one shared body for the two clear clauses. The two heads differ, and the body is one line.

Standards: no hard violation. Three doc wording points on "keypress" against "key press, key repeat, or paste". Fixed in round 1. Judgement calls not applied: the names `send_error/1` and `ViewModel.reject/2`. `send_error/1` follows `model_error/1` in the same module. `reject/2` follows `notice/2`: the caller says what happened, and the view model decides what to keep.

Spec: all four acceptance boxes met. Partial: no test reaches `send_error(:invalid_utf8)`. Accepted, because `edit/3` lets only valid UTF-8 into the composer, so the case has no source; the clause keeps the match total over the spec of `Session.steer/2`. One finding confirmed and shared with the failure-path axis: the reason came after the model span.

Failure-path, two findings, both reproduced:

1. Medium: the status line does not wrap, and a model ref can be 256 bytes. A 200-character model and a render at width 80 put the reason at column 227. Fixed: the reason is the first span. A test renders a 256-character model.
2. Low: a `repeat` of the rejected Enter cleared the reason, and no resend occurred. Fixed: only kind `press` and a paste clear the reason. A test covers `release` and `repeat`.

## Round 2 (full)

The fix changed about 20 lines in one code file, over the 15-line limit, so the round was full. Simplify ran as two agents with two angles each, not four agents. Both were clean, with the same optional shared-body point, skipped again.

- Standards: no hard violation. Wording: "removes" against "clears", and "keypress" in two test comments. Fixed. The `reject/2` name came up again; not applied, reason above.
- Spec: clean. Both reproductions of round 1 hold. The texts, the 31 bytes, and the 35 columns in the doc are true of the code.
- Failure-path: one low finding, reproduced. A `repeat` key with invalid text replaces a set reason through `edit/3`, and the doc did not say so. This is the intended behaviour: the newest reject is the one the user must see. Fixed in the docs: the feature doc and the `ViewModel` moduledoc state that a new reject replaces the reason.

## Round 3 (reduced)

The fix changed 4 lines of doc text in one code file, plus test comments and Markdown. No function changed. Reduced round: spec and failure-path.

- Spec: 0 findings. Seven inputs probed.
- Failure-path: 0 findings. 21 throwaway tests, renders at widths 34, 35, and 36 with a 256-byte model ref.
