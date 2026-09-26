# Review: one turn flag in place of the provider kind (#123)

Base: `origin/master` at `d1f95aa`. Three rounds: the first and complete round, one full rerun round, and one reduced rerun round.

## Change

`Helyx.Provider.kind/0` (`:model` or `:harness`) is now the optional `turn/0` (`:local` or `:external`, default `:local`), as `docs/features/external-turn.md` says. `Helyx.Provider.turn/1` replaces `kind/1`. The `kind` field of the session `State` and of `Helyx.Session.Turn` is now `turn_mode`. The `harness?` key of `Helyx.Session.Stream.run/1` is now `external?`. The error `{:bad_provider_kind, id}` is now `{:bad_provider_turn, id}`. ClaudeCode and Codex define `turn/0` as `:external`. The `harness_session` data names do not change. ADR 0002 has a `## Revision` section with the approved text. `CONTEXT.md` and `docs/features/coding-agent.md` name the turn flag where a sentence is about a decision of Core.

Invariant: a rename of the decision only. Behaviour, events, the transcript, and the session file do not change. No assertion of an existing test changed, except the renamed names. A new test file, `test/helyx/interfaces/provider_test.exs`, shows that a provider with no `turn/0` gets a local turn.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

The same line for each round.

## Round 1

### Simplify

- Fixed (altitude): the default-turn test was in `session_test.exs`. It is now in `test/helyx/interfaces/provider_test.exs`, next to the function it tests. `function_exported?/3` needs a loaded module, so the test loads the providers first. In a session, `Helyx.Provider.find/2` loads the module first, with its call to `id/0`.
- Skipped (simplification, altitude): pass `turn_mode` to `Stream.run/1` in place of the `external?` boolean. The design doc names the `external?` key.
- Skipped (simplification): a shorter Provider moduledoc that points to the Session moduledoc. The design doc asks the Provider moduledoc to describe an external turn by its four behaviours.
- Reuse, efficiency: no findings.

### Standards

No hard violations. Judgement calls:

- Fixed: the sentence of four clauses in the Provider moduledoc is now a list of four behaviours.
- Fixed: two comments that named the turn as the actor now name the provider (`stream.ex`, the open-calls branch of `end_turn/2`).
- Fixed: two long lines after the reflow (the Session moduledoc, the comment of `Helyx.Test.Harness`).
- Fixed: the test name and its body differed. The test is split in two.
- Skipped: repeated switches on `:external`, `turn.turn_mode`, and the kept "harness" names. The design doc requires all three.
- Skipped: a devlog. The orchestrator records the session.

### Spec

No findings. Every item of the doc is met. The ADR revision text is byte for byte the approved text. The two greps of the doc's Tests section find no provider kind and no branch. Optional notes, skipped: `lib/helyx/hands.ex` and `lib/helyx/interfaces/event.ex` say "harness provider" or "harness turn" in text that the doc does not list. The doc keeps "harness provider" as the product term and names only the session, stream, and provider files. `docs/features/session-stream.md` still shows `harness?: boolean()`. It is the design record of #120, not the living spec, and #123 does not ask for a change to it.

### Failure path

One finding, reproduced, rejected. A provider outside this repository that still defines `kind/0 -> :harness` and no `turn/0` gets a local turn and no error. The design doc says: "The old names are removed, with no alias and no delegate. Every caller is in this repository." No module in this repository defines `kind/0`.

## Round 2 (full)

The fix of round 1 changed 26 code lines (comments and moduledocs only) in three code files, so the rerun is a full round.

### Simplify

- Fixed: a comment of `Helyx.Test.Harness` had a line break in the middle of a sentence.
- Skipped: two comments say "a provider with an external turn" and others say "an external turn". The two comments name the actor that sends or runs something. The others use the turn as a noun ("the steer of an external turn").
- Reuse, efficiency, altitude: no findings.

### Standards

No hard violations. Judgement calls:

- Fixed: the name of the second provider test did not say what it asserts.
- Skipped: one sentence of three statements in the Session moduledoc. The sentence is older than this change. Only its line break moved.
- Skipped: the other comments that use "an external turn" (see Simplify).
- Skipped: "the session's hands" in the Provider moduledoc. The paragraph on the stream Task in the same moduledoc names `Helyx.Hands`.

### Spec

No findings. The fix keeps the invariant. Optional note: the Provider bullet for behaviour 2 leaves out the aborted result of an open call. Round 3 added it and then removed it again (see Round 3).

### Failure path

No reproduced findings. The fix has no code line.

## Round 3 (reduced)

The fix of round 2 added 2 moduledoc lines in one code file and renamed a test, so the rerun is a reduced round.

### Spec

No findings.

### Failure path

One finding, reproduced and fixed. The added sentence "A call with no result at the end gets an `aborted` result" holds only when the call ends with `done`. When a turn fails, ends with no terminal, or is steered while a message is open, the partial message is dropped with its calls (the checklist line "A partial assistant message from a failed turn is not added to the transcript"). The sentence is removed. The `message_end` bullet of the same moduledoc states the exact rule. After the removal, `lib/helyx/interfaces/provider.ex` is the text that round 2 reviewed. The only change after round 2 is the test name, so no code needs a new review.

## Orchestrator

- Codex adversarial review, round 1: approve, 0 findings.
- Accepted: the rejected round 1 finding (a provider with only `kind/0` gets a local turn), because the design removes the old names with no alias and no module in the repo defines `kind/0`.
