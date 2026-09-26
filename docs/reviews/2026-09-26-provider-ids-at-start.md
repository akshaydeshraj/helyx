# Review: check provider ids once at Core start (#169)

Base: `origin/master` at `ca7081d` in round 1, rebased on `27be8aa` (#178) before round 2. Three rounds: the first and complete round, then two reduced rounds.

## Change

`Helyx.Core.start_link/1` calls `Helyx.Core.Plugins.provider_ids/1` after `resolve/2`. It calls `id/0` of each provider once, in the caller, contains a raise, a throw, or an exit, and rejects a value that is not a binary with `{:invalid_provider_id, plugin}` and a shared id with `{:duplicate_provider_id, id, [first, second]}`. The id to module map goes into the meta of the sessions Registry, next to the plugin table (#165), and `Helyx.Core.provider_ids/1` reads it. `Helyx.Provider.find/2` is a `Map.fetch` on it. `{:bad_provider_id, _}` and `{:ambiguous_provider, _}` leave `find/2`, its spec, `Helyx.Session.model_error/0`, the TUI notice, and `CodingAgent.error_text/1`. The #153 tests of the session and the TUI become Core start tests in `test/helyx/core_test.exs`.

Invariant: a provider `id/0` runs only at Core start, in the caller of `Helyx.Core.start_link/1`, contained there; `find/2` calls no plugin code; the printed Core start error of `mix helyx` keeps the bound that the Provider id row states.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Fixed: `find/2` read the Registry meta itself. `Helyx.Core.provider_ids/1` now reads it, next to `Helyx.Core.plugins/2` (reuse, simplification, altitude).
- Fixed: `find/2` passed `{:ok, plugin}` through a `case`; it is now a `with :error <-`.
- Fixed: the `find/2` doc repeated the contract of the moduledoc; it is shorter now.
- Skipped: move `provider_ids/1` into `Helyx.Provider` (altitude). The ticket puts the check at `Plugins.resolve/2` or next to it, and an interface module stays a behaviour and public API (AGENTS.md).
- Skipped: a blank line in the feature doc list. The sentence after it is not a list item.
- Efficiency: no findings.

### Standards

- Fixed (hard): `docs/agents/review-checklist.md` still said that `id/0` is contained in `find/2`. It now states the Core start boundary.
- Fixed: a moduledoc line over the wrap width.
- Skipped: `invalid_provider_id` against the `bad_*` prefix. A new name keeps the removed `bad_provider_id` term out of every path, as the ticket asks.
- Skipped: the two-item list in `duplicate_provider_id`, as in `mode_violation`.
- Skipped: Core knows one interface (`table[Helyx.Provider]`). The ticket places the check at Core start, and `Helyx.Provider` is already in the fixed boot list.
- Skipped: Middle Man on `Helyx.Core.provider_ids/1`, the same shape as `plugins/2`.

### Spec

- Fixed: the checklist line (same as Standards).
- Fixed: the `mix helyx` paragraph of the feature doc did not list the Core start errors among the `inspect/1` fallback errors.
- Fixed: no test covered the render path of the new errors. `coding_agent_test.exs` now checks `error_text/1` for both.
- The worktree base was stale (#178). Rebased before round 2.

### Failure path

No reproduced findings. Raise, throw, exit, an integer, a charlist, two providers with one id, one module listed twice, and a start under a Supervisor all give `{:error, _}`. Outside the diff: a killed sessions Registry stopped Core in one probe; it is not from the new meta and was not compared on master.

## Round 2 (reduced)

The fix diff without tests and Markdown: 2 lines, one file (a moduledoc rewrap). Reduced round: spec and failure path.

- Spec: no findings.
- Failure path, 2 findings, both fixed in the Provider id row: `inspect/1` escapes a category Cf character such as U+202E in 6 bytes, so 4,096 characters print as about 24.6 KB, not 16 KB; and a binary that is not printable prints 50 elements (528 bytes), not 50 bytes. The test now checks a U+202E id, a bound of 24,700 bytes, and no control byte.

## Round 3 (reduced)

The fix diff without tests and Markdown: 0 lines. Reduced round: spec and failure path, briefed on the render bound.

- Spec: no findings. Nit, fixed: the measured figure depends on the module names, and the row gave no bound for the whole error. The row now names the case and states about 28,700 bytes for the whole error.
- Failure path: no findings. Every code point was inspected: no string escape is longer than 6 bytes, and no module name character longer than 8 bytes. No output held a control byte.

## Orchestrator

- Codex adversarial review, round 1: no finding. The base did not change after the precommit run of the worker.
- Accepted: the start errors are named `invalid_provider_id` and `duplicate_provider_id`, so the removed `bad_provider_id` does not come back with a new meaning.
- Accepted: the new start errors print through the `inspect/1` fallback of `CodingAgent.error_text/1`, as the other Core start errors do. The tuple names the plugin.
- Older than this change: a killed sessions Registry stops Core with `:shutdown`. Reproduced on master (27be8aa) and recorded on #116.
