# Review: one layer for the watchdog calls of the harness providers (#125)

Base: `origin/master` at `ef03335`. One round: the first and complete round. Step 2 changed only Markdown, so no rerun round.

## Change

`Helyx.HarnessIO` gets `write/2`, which writes to the port of a run state through `Helyx.Watchdog.write/2`, and `release/3,4`, a delegate to `Helyx.Watchdog.release`. `Helyx.Provider.Codex` calls `HarnessIO.write/2` for its request lines and the end of input, and `HarnessIO.release/4` with its 5,000 ms grace. `Helyx.Provider.ClaudeCode` delegates `release/3` to `HarnessIO`, and the exit timeout of a lost session calls `HarnessIO.stop/1` in place of `Helyx.Watchdog.close/1`. Comments in `harness_io.ex` and `watchdog.ex` say that the harness providers reach the watchdog through `HarnessIO`.

Invariant: the two harness providers call no `Helyx.Watchdog` function, and every watchdog call keeps its arguments, grace, and deadline. No test assertion changed.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude. No findings. Before the agents ran, the `HarnessIO` header comment was reflowed and now lists the `port` field.

### Standards

No hard violations. Judgement calls:

- Fixed: ADR 0005 said that `ClaudeCode` delegates `release/3` to `Helyx.Watchdog`. A dated revision for #125 now records the layer.
- Skipped: Middle Man on `HarnessIO.release`. The ticket asks for this layer.
- Skipped: the `opts \\ []` default repeats the default of `Group.release/4`. `ClaudeCode.release/3` needs `HarnessIO.release/3`.
- Skipped: `stop/1` wraps `close/1` under another name. The name is older than this change.

### Spec

No findings. The release grace stays 500 ms for Claude Code and 5,000 ms for Codex; the exit wait and the interrupt wait are not in the diff. A `nil` port in `exit_timeout` now returns `:ok` in place of `false`; no caller reads the value. Fixed: the ADR revision said that `start` is newly wrapped; it was wrapped before.

### Failure path

No reproduced findings. A throwaway probe checked `write/2` with a `nil` port and a closed port, `stop/1` on a closed port, the arity of the release delegates, and the grace that reaches `Helyx.Watchdog.Group`. The results match `master`.
