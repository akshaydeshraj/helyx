# Review: default model context and compaction seams (ticket #8)

Scope: `Helyx.ModelContext` and `Helyx.Compaction` interfaces, session wiring,
`plugins/model_context_default`, `plugins/compaction_none`. Reviewed through
`/ship`: simplify (four angles), then standards, spec, and failure-path axes.

## Simplify pass

| Finding | Resolution |
| --- | --- |
| `build`/`compact` ran in the session GenServer, outside the turn Task. A plugin that raises would kill the session, and slow plugin work would block prompts and abort. | Fixed. Context building moved inside the provider Task. |
| `Default` used `File.read/1`, an unbounded read exempt from the repo's own input limits. | Fixed. Uses `Helyx.Tool.read_file/1` (bounded, regular files only). |
| Hand-rolled byte-offset helper for order assertions in `default_test.exs`. | Fixed. One `~r/a.*b.*c/s` assertion. |
| `Keyword.get_lazy` for the `:home` default. | Fixed. `opts[:home] || System.user_home!()`. |
| Drop `plugins/compaction_none`; the interface's `[] -> context` clause is the same no-op. | Skipped. The ticket requires the no-op plugin so the seam is real from the start. |
| Duplicated single-plugin dispatch in `ModelContext` and `Compaction`. | Skipped. Two occurrences; extract a `Helyx.Core.plugin/2` helper when a third `:single` interface lands (Transport). |
| Duplicate-rejection tests and Twin doubles re-prove generic mode checking. | Skipped. They pin that both new interfaces declare `mode: :single`, an explicit acceptance criterion. |
| Fake-provider integration test duplicates the session seam test. | Skipped. The acceptance criterion names the Fake provider; the session test additionally covers compaction ordering. |
| Cache the AGENTS.md read per session instead of per provider call. | Skipped. The ticket specifies building per call; the read is a few small local files and no longer blocks the session. |

## Standards axis

No hard violations. Judgement calls noted, not taken: rename `chain/2`;
bundle the provider-call opts into a struct when they grow again; wildcard
the plugin list in the root precommit alias. The moduledoc gap (unreadable or
oversize `AGENTS.md` also skipped) was fixed, see below.

## Spec axis

| Finding | Resolution |
| --- | --- |
| No test registers `Compaction.None` with a Core; only a direct function call. | Fixed. `none_test.exs` boots Core with the plugin and asserts through `Helyx.Compaction.compact/3`. |
| `Default` skips unreadable and oversize files, not only missing ones, and the moduledoc did not say so. | Fixed. Moduledoc states the rule. |
| A cwd outside home (or reached through a symlink with an explicit `cwd:`) contributes only its own `AGENTS.md`; `~/AGENTS.md` is dropped. | Accepted. The chain from home to cwd does not exist in that case. Documented in the moduledoc and tested. |
| `:home` option is test-only surface. | Accepted. One line; the alternatives cost more. |

## Re-pass on the review fixes

The fixes above (the `None` registration test and the moduledoc sentence)
went through the loop again. Simplify, standards, and spec came back clean;
an async-test flag from standards was a false positive (each test boots Core
under a unique name, the repo's established pattern). Failure-path found the
new test vacuous on dispatch: the assertion also passed with no compaction
plugin registered, because the interface's no-plugin clause returns the
context unchanged too. Fixed by also asserting
`Helyx.Core.plugins(core, Helyx.Compaction) == [Helyx.Compaction.None]`.

## Failure-path axis

Probed with throwaway tests under `.scratch/review/` (deleted): a raising
ModelContext or Compaction plugin, a plugin returning a non-Context value, a
raise on the second provider call, AGENTS.md as directory / chmod 000 /
broken symlink / over the byte limit, `home: "/"`, prefix near-collisions
(`/Users/foo` vs `/Users/foobar`), duplicate and nonexistent plugin modules.
No defects. Every failure lands in the existing fail-the-turn path and the
session accepts the next prompt.
