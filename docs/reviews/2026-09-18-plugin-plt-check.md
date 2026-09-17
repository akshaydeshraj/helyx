# Review: plugin Dialyzer PLT check

Scope: `fix/plugin-plt-check`, build configuration only, nine `mix.exs` files and lock files.

## Why

Master failed precommit after PR #22 merged: the bash plugin's Dialyzer reported `Helyx.Tool.register_group/1` as missing although core defines it. The plugin's PLT held the core beams from an earlier build. Dialyxir rechecks a PLT only when the lock file changes, and a path dependency never changes it, so every core API change left the plugin PLTs stale. `mix dialyzer --force-check` reproduced the fix: zero errors.

Three plugins, `provider_openai`, `model_context_default`, and `compaction_none`, had no Dialyzer at all. Their branches predate #19.

## Change

- Every plugin precommit alias runs `dialyzer --force-check`.
- The three plugins without Dialyzer get the dependency and the alias.
- The root alias comment explains the forced check.

## Review

One agent covered the three axes, since the diff is build configuration with no code. Standards: the dialyxir line and the alias are identical across all eight plugins; two new lock files were untracked and are now committed. Spec: every plugin runs the forced check, and the root comment matches how dialyxir hashes `mix.lock` and the app list, which a path dependency never changes. Failure path: `--force-check` runs a PLT check that compares beam checksums, so it also catches a removed or retyped core function; `--no-check` and `plt_add_deps` do not address staleness.

## Failure path

Reproduced by hand before the change: stale PLT in `tool_bash` reports a missing function; forced check clears it. Cost: about twelve seconds per plugin per run after the first PLT build.
