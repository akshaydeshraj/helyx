# Review: resolve the context and compaction plugins once per session (#122)

Base: `origin/master` at `49dbef9`. One round: the first and complete round. Step 2 changed no code, so no rerun round.

## Change

`start_child/1` in `lib/helyx/session.ex` resolves the ModelContext and Compaction plugins one time, in the caller of `start/2` and `resume/2`, and keeps them in two new `State` fields. `nil` means no plugin. `Helyx.Session.Stream.run/1` gets `model_context` and `compaction` in place of `core`. It calls `build/2` and `compact/2` on the modules, and it skips a `nil` module. The context build and compaction still run before every provider call. `Helyx.ModelContext.build/3` and `Helyx.Compaction.compact/3` stay unchanged for other callers.

Invariant: a provider call reads nothing from the plugin table, and it gives the same context as before. A new session test suspends the `Plugins` Agent during a turn and gets the full "built for ..., compacted" answer. No assertion of an existing session test changed.

Doc fix: `docs/features/session-stream.md` shows the new arguments of `run/1`.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Fixed: the private `single_plugin/2` helper is now `List.first/1` on `Helyx.Core.plugins/2`. Core refuses to start with two plugins for a single-mode interface, so the list has zero or one entry. The comment says so.
- Fixed: the feature doc still named `build/3` and `compact/3` and the `core` argument.
- Skipped: a shared "single plugin" helper in `Helyx.Interface`. The ticket keeps `build/3` and `compact/3`, and one caller does not need a new public function.
- Efficiency: no findings.

### Standards

No hard violations. Judgement calls:

- Skipped: the inline `if` in `run/1` repeats the dispatch of `build/3` and `compact/3`. The ticket keeps those functions and asks for a new public function only when one is needed.
- Skipped: `List.first/1` does not reject a second plugin. Core rejects it at start (see Simplify).
- Skipped: the test builds the Agent name with `Module.concat(core, Plugins)`, a copy of the private `plugins_name/1`. A new accessor only for a test is scope creep.
- Skipped: the last `:sys.resume/1` of the test repeats the `on_exit` resume. It releases the Agent before the Core stops, which keeps the cleanup clear.
- Skipped: `model_context` and `compaction` travel together (data clump). Two fields do not need a type.

### Spec

No findings. Every acceptance criterion is met. The plugins resolve in `start_child/1`, which both start and resume call, next to the provider resolve. The comment states that the plugin table of a Core does not change after start.

### Failure path

No reproduced findings. A throwaway test confirmed that a lookup against the suspended Agent exits with a timeout, so the new test catches a lookup. A plugin that raises, or that returns a value that is not a context, fails only the turn; the next prompt works. That behaviour is the same on `master`.
