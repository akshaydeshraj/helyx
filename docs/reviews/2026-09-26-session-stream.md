# Review: `Helyx.Session.Stream` runs the provider call (#120)

Base: `origin/master` at `40389b4`. One round: the first and complete round. Step 2 changed no code, so no rerun round.

## Change

The code that runs in the provider Task leaves `lib/helyx/session.ex` for `Helyx.Session.Stream` (`lib/helyx/session/stream.ex`, `@moduledoc false`). `run/1` builds the context, compacts it, calls `provider.stream/3`, checks each stream event, sends each event that passes to the session, and returns the first terminal through `Message.cap_integers/1`. `consume/4`, `harness_event/1`, `done_terminal/3`, `capped_usage/1`, and `forward/5` moved with no change to their bodies. The provider Task closure in `call_provider/1` is now `fn -> Helyx.Session.Stream.run(args) end`. The checks of `:DOWN`, `:stream_end`, and client text stay in the session. The `kind` flag stays (#123).

Invariant: the session sends the same events, in the same order, with the same data, for every stream. `test/helyx/session_test.exs` has no diff against the base.

Doc fixes in `docs/features/session-stream.md`: the old line numbers (`session.ex:653-828`, `:681`, `:470-475`, `:478-480`) are replaced by function and clause names. The session was 931 lines after #119, not 998. The closure was built in `call_provider/1`, not in `start_provider_call/1`, so the doc now says that the session keeps `call_provider/1` too. The rows of `docs/features/coding-agent.md` that named the session or `consume/3` as the place of a stream check now name `Helyx.Session.Stream`.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Fixed: `call_provider/1` compared `kind == :harness` three times. It now binds `harness?` one time.
- Fixed: `run/1` read five keys from its head and three with `args.`. All eight keys are now in the head.
- Skipped: `core` and `turn_id` go to `run/1` both as keys and in `opts`. The feature doc fixes the argument map. #123 changes this path.
- Skipped: the second cap of the `:stream_end` terminal in the session. The feature doc keeps it, because the hands can make a terminal of their own.

### Standards

No hard violations.

- Fixed: two test names were not clear STE ("leaves capped", "may send").
- Skipped: the name `Stream` shadows the Elixir `Stream` when it is aliased. The feature doc and the ticket name the module. The session calls it with its full name, and the test aliases it as `SessionStream`.
- Skipped: the data clump of `session` and `turn_id` through `consume/4` and `forward/5`. It is moved code, and the change is a move.
- Skipped: the sentence of the feature doc that names `consume/3`. It quotes the old rows of `coding-agent.md`, which said `consume/3`.

### Spec

All acceptance criteria met, except `mix precommit`, which the reviewer did not run (see Precommit). No scope creep. The body of `stream.ex` is the same as the removed code: the guards, the clause order, the `:stream_ended` accumulator, the order of `rejected_call` before `stream_event`, and the final cap. The 100-digit cap applies before any event reaches the session, so no bound moves away from the render path.

### Failure path

No findings. Probes: an empty stream and a lazy stream with no terminal, a `done` with an unknown stop reason, with a usage that cannot be encoded, and with an extra key; a harness id of 256 bytes (multibyte), 257 bytes, and 0 bytes; a cut of -1 and of 101 digits; a harness result id that is not valid UTF-8; a harness event from a model provider; tool call arguments that are not valid UTF-8; an error reason with 101 digits; a stream that raises.

## Precommit

Passed on the first run: root 196 tests and 1 property, `plugins/bundled` 289 tests, `apps/coding_agent` 17 tests, 0 failures.

## Orchestrator

- Codex adversarial review, round 1: approve, 0 findings.
- Note for #123: the `kind` flag now appears in two places, the session and the `harness?` key of `Helyx.Session.Stream.run/1`. #123 removes both.
