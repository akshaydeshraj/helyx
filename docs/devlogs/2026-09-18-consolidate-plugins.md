# 2026-09-18: one Mix project for the bundled plugins (ticket #38)

## Done

- `git mv` of the nine plugin projects into `plugins/bundled`, app `:helyx_plugins`. Module names and registration entries did not change. `apps/coding_agent` changed only its dep list: `helyx_plugins` and `ex_ratatui`.
- `req` is a normal dependency, `plug` is `only: :test`, `ex_ratatui` is `optional: true`.
- The nine `test_helper.exs` files merged into the Bash one; the other eight held only `ExUnit.start()`. No tag excluded a test, so there was nothing to keep there. 124 tests moved, 1 added.
- ADR 0005 records the reversal, the optional-dependency rule, and what was given up.
- `AGENTS.md`, `README.md`, the coding-agent feature doc, and `.credo.exs` describe the new layout.

## What broke

- The `Code.ensure_loaded?/1` guard alone did not hold the acceptance box "With `ex_ratatui` added, `Helyx.TUI` is available". A product that added `ex_ratatui` after its first build kept a build without `Helyx.TUI`. Mix reaches a stale source only through a module the source defines, and the guarded file defined none. The fix is `Helyx.TUI.Available` in `tui.ex`, a module that always exists, with `__mix_recompile__?/0`. A first attempt with that module in its own file did not work, for the same reason.
- `Helyx.TUI.ViewModel` has no guard. It needs nothing from `ex_ratatui`, and a guard would need a second always-present module. This deviates from the ticket text, which says "the TUI modules".
- The OpenAI test seam key moved with the app: `:openai_req_options` of `:helyx_plugins`.

## Numbers

Root `mix precommit` on a fresh worktree: see `docs/reviews/2026-09-18-issue-38.md`.

## Next

- Nothing open from this ticket.
