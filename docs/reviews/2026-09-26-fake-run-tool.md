# Review: `Fake.run_tool/3` to test support (#126)

Base: `origin/master` at `e4f96d4`. One round, the first and complete round.

## Change

`run_tool/3` moves from `Helyx.Provider.Fake` in `plugins/bundled/lib` to `Helyx.Test.ToolRunner` in `plugins/bundled/test/support/tool_runner.ex`. `plugins/bundled/mix.exs` compiles `test/support` only in the test environment. The four tool tests (`bash`, `edit`, `read`, `write`) call the new module. Their assertions do not change.

Invariant: no module in `plugins/bundled/lib` calls a `Helyx.Session` function.

Callers checked in all Mix projects: only the four tool tests called `Fake.run_tool/3`. `mix helyx.graph` in `apps/coding_agent` calls only `Fake.script/3`. Its test names `Helyx.Session.run_tool/2`, a private function of the session, which this change does not touch.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Simplify

Four agents: reuse, simplification, efficiency, altitude. No fixes.

- Skipped: shorten the `@doc` of `run_tool/3` to a comment. AGENTS.md asks for `@doc` on public functions.
- Skipped: `bash_test.exs` spells `Helyx.Provider.Fake` in full next to its alias. That was there before this change.
- Skipped: move `Helyx.Test.OSHelpers` from `test_helper.exs` to `test/support/`. Out of scope for #126.

## Standards

No violations. Three judgement calls, none applied:

- `ToolRunner.run_tool/3` stutters. Kept: the ticket names `run_tool/3`.
- The four tests repeat one closure that builds a `ToolCall`. That was there before this change, and the ticket keeps the tests unchanged apart from the call target.
- No devlog. The cleanup plan, G5, is the design, and earlier tickets of the plan record their review here only.

## Spec

All acceptance criteria are met. No scope creep apart from one sentence in the `@doc`: "Core must run `Fake`."

## Failure path

No findings. The helper body did not change. The helper is not loaded in the dev environment, and an app that depends on `helyx_plugins` does not get it in its test environment.

Two points that were there before this change, not reproduced as defects: the `receive` does not check the call id, which is safe because each helper session has exactly one call; the helper does not stop its session, and the supervised Core of the test cleans it up.

## Orchestrator

- Devlog question: no per-ticket devlog. The orchestrator writes one devlog for the run.
- Codex adversarial review, round 1: approve, 0 findings. Its note that the invariant was too broad is correct: `Helyx.TUI` is a client and calls `Helyx.Session` by design. The invariant is that no provider plugin calls a `Helyx.Session` function.
