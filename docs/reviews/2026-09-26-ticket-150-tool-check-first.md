# Review: tool check before the session file (#150)

Base: `origin/master` at `79c0604`. Round 1 is the first and complete round. Round 2 is a full rerun round for the fix of round 1.

## Change

`Helyx.Tool.check_available/1` runs the optional `check/0` of each tool that `Helyx.Tool.specs/1` returned. `Session.start/2` and `Session.resume/2` call it in the `with` chain, right after `specs/1`. This is before the model ref resolves, before the sessions directory is read, and before a file is created or repaired or a process starts. `Hands.init/1` no longer runs `check/0`.

Invariant: at the two entry points `Session.start/2` and `Session.resume/2`, a failed tool check (an error, a bad value, a raise, a throw, or an exit) gives `{:error, {:tool_unavailable, name, reason}}` before any file or process is created. The plugin boundary is `check/0`, and its value is checked there.

Decisions:

- `{:error, reason}` passes its reason when the reason is a string of valid UTF-8. Any other value but `:ok` gives the fixed reason `check/0 returned a bad value`. Before, the hands treated such a value as a pass. This follows the boundary rule in `AGENTS.md`.
- A raise, throw, or exit gives the fixed reason `check/0 raised, threw, or exited`, with the tag `:tool_unavailable` and the checked spec name. `CodingAgent.error_text/1` needs no new clause.
- The check has no deadline, as for a spec callback. The feature doc row states this.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

- Fixed: `checked_result/1` called itself with a dummy value to reach its fallback. It now uses `text?/1` and one fixed-reason attribute.
- Fixed: the moduledoc of `Helyx.Tool.Bash` still said that `check/0` runs when the hands start.
- Skipped: run the checks in parallel with a shared timeout. This changes behaviour, and the tool count is small.
- Skipped: test `check_available/1` directly. The ticket asks for tests through `start/2` and `resume/2`.

### Standards

- Fixed: the new feature doc row gave no bound for the reason text. It now says "no size limit", as the spec row does.
- Fixed: a moduledoc line was not re-wrapped.
- Fixed: the two fixed reasons are now module attributes at the top of `Helyx.Tool`.
- Not changed: the duplicated test module generator of #142, one `test` for many cases, and no test file for `Helyx.Tool`. The #142 tests use the same patterns.

### Spec

- Fixed: the comment of `Helyx.Test.Tool.Unavailable` said that the hands refuse to start.
- Fixed: the feature doc now says that the check runs before the model ref resolves.
- Accepted: the stricter check of the return value, which the ticket did not ask for. The boundary rule requires it, and the feature doc states it.

### Failure path

No reproduced defects. Probes through `start/2` and `resume/2`: `exit(:kill)`, `throw({:error, "x"})`, `{:error, ""}`, two failing tools, a bad model with a failing check, and a missing sessions directory.

- Fixed: the `{:error, reason} -> {:stop, reason}` branch after `Hands.start_link/1` in `Server.init/1` could not run any more. `Server.init/1` now matches `{:ok, hands}`.

## Round 2

Full round: the fix changed two code files (`lib/helyx/interfaces/tool.ex`, `lib/helyx/session/server.ex`) and more than 15 lines. Base: the round 1 state.

### Simplify

Four agents: no findings.

### Standards

- Fixed: add a test that the check runs before the model ref resolves.

### Spec

- Fixed: ADR 0004 still said that a system without perl fails when the hands start.

### Failure path

No path makes `Hands.start_link/1` fail. One reproduced finding is older than this diff:

- Open, out of scope: `Session.resume/2` resolves the model ref (`Helyx.Provider.find/2`, `turn/0`) after `Helyx.Session.File.resume/2`, which repairs a torn last line. A missing provider or a `turn/0` that raises then gives an error, but the file has lost its torn line. The model ref comes from the file, so a fix must split the read from the repair in `Session.File.resume/2`. The review checklist now records this as open. It needs a ticket.

The round 2 fixes change only tests and Markdown, so no further round is needed.

## Orchestrator

- Codex adversarial review, round 1: no finding. The base did not change after the precommit run of the worker.
- Accepted: the stricter return check of `check/0` (a value other than `:ok` or `{:error, string}` fails the start). The boundary rule requires it.
- The open resume item is #104, which the owner accepted and closed. The checklist line now says so.
- ADR 0004 names `Helyx.Watchdog.start/4` (from #152, item 6).
