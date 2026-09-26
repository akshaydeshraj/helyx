# Review: TUI notice for a provider with a bad turn/0 (#145)

Date: 2026-09-26. Base: `origin/master` at e1e14d3. Ticket #145, finding D3 of `docs/reviews/2026-09-26-boundary-review.md`.

## Invariant

The return of `Helyx.Session.set_model/2` is the boundary for the `/model` command of the TUI (`switch_model/2` in `Helyx.TUI`). Each error that its `@spec` lists gets one `model_error/1` clause and a notice, and there is no catch-all clause. The four errors are `:invalid_model_ref`, `:unknown_provider`, `:ambiguous_provider`, and `:bad_provider_turn`. The `@spec`, the `@doc`, the model switching paragraph of `docs/features/coding-agent.md`, and the TUI clauses name the same four. A notice shows at most the provider id, which `ModelRef.parse/1` bounds.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (4 agents): reuse 1, simplification 0, efficiency 0, altitude 0.

- Skipped: the test provider `Helyx.TUI.Test.Provider.BadTurn` copies `Helyx.Test.BadTurn` of the root `test/support`. The `plugins/bundled` project does not compile the root `test/support`, so the copy stays.

Standards: 0 hard findings, 1 judgement call (the same copy, kept). One doc gap outside the diff: the `@doc` of `set_model/2` did not name a provider with a bad `turn/0`.

Spec: 0 blocking findings. One doc gap: the error lists in the `@doc` of `set_model/2` and in the model switching paragraph of `coding-agent.md` omitted `:bad_provider_turn`.

- Fixed: both lists now name the error.

Failure-path: 0 findings. Probes through `TUI.handle_event/2` with providers whose `turn/0` raises, throws, exits, returns `nil`, and returns `:bogus` with a multibyte id of 240 bytes: each gave the notice, and the session model did not change.

## Round 2 (reduced)

The fix changes 3 lines of `@doc` text in one code file and one line of Markdown. It adds no function and changes no spec, so the round is reduced: spec and failure-path.

Spec: 0 findings. Failure-path: 0 findings.

Both agents reported one gap out of the scope of the ticket: `CodingAgent.error_text/1` (`apps/coding_agent/lib/coding_agent.ex`) has no clause for `{:bad_provider_turn, id}`, so a start or a resume with such a provider prints the tuple through `inspect/1`. It does not crash. Its `@doc` says it has a clause for the provider errors. The bundled plugins cannot cause it. Not fixed here; the ticket puts other error paths out of scope.

## Precommit

`mix precommit` passed in the root, `plugins/bundled`, and `apps/coding_agent`.

## Orchestrator

- Codex adversarial review, round 1: no finding. The base did not change after the precommit run of the worker.
- Filed as a follow-up: `CodingAgent.error_text/1` has no clause for `{:bad_provider_turn, id}`.
