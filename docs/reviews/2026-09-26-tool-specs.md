# Review: tool specs checked once at session start (#142)

Base: `origin/master` at `706ddd0`. Round 1 is the first and complete round. Round 2 is a full rerun round for the fix of round 1.

## Change

`Helyx.Tool.specs/1` replaces `by_name/1` and `spec/1`. It calls `name/0`, `description/0`, and `parameters/0` of each tool plugin once, checks the spec, and returns `[{module, spec}]` sorted by name. `Helyx.Session.start/2` and `resume/2` call it right after the `cwd` check, before the model resolves, before the sessions directory is read, and before a file or a process is created. The session stores the specs in its state and uses them for every provider call. The hands get the tool module by name as the new `tools:` option. `Hands.tools/1` is deleted, and `Hands.init/1` no longer reads the plugin table.

Invariant: the tool specs that every provider call sends are the values that `Helyx.Tool.specs/1` checked at session start, and the spec callbacks run once per session.

Decisions:

- Accepted shape: `name` a non-empty string of valid UTF-8; `description` a string of valid UTF-8; `parameters` a map whose top-level keys are strings and that `Helyx.Message.encodable?/1` accepts. Nested keys are not checked: the ticket puts JSON Schema validation out of scope, and `encodable?/1` already rejects nested values that JSON cannot hold.
- The error label is the name when the name passes, else `inspect(module)`, an atom text of at most 255 characters.
- Two tools with one name keep `{:error, {:duplicate_tool_name, name}}`, the existing shape and test, not `{:bad_tool_spec, name}`. The feature doc row states this.
- A spec callback that raises raises in the caller of `start/2` or `resume/2`, as the provider lookup does. Plugins are compiled into the node, and the checklist checks shape, not values.
- `CodingAgent.error_text/1` gets no new clause. `{:bad_tool_spec, label}` goes through the `inspect/1` fallback with its limits and the clean pass, like `{:duplicate_tool_name, _}`. The feature doc lists it.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Fixed: `Hands.State.tools` had two shapes (a list before `init`, a map after). The session now gives the hands the map, and the field has one shape.
- Fixed: the server rebuilt the spec list from `[{module, spec}]` on each provider call. The session now stores the specs (`tools`) and the module map (`tool_modules`) once, at start.
- Skipped: `names -- Enum.uniq(names)` is quadratic in the number of tools. The old code did the same, and the tool count is small.
- Reuse, altitude: no other findings. `Helyx.Message.valid_utf8?/1` returns `true` for `nil` and atoms, so it cannot replace `text?/1`.

### Standards

No hard violations in code. Findings:

- Fixed: the bounds row "session to hands calls" in `docs/features/coding-agent.md` named the deleted `Hands.tools/1`.
- Fixed: the `@doc` of `specs/1` now says "at the top level", as the feature doc does.
- Fixed: the `Counted` test erases its `:persistent_term` key in `on_exit`.
- Skipped: `docs/features/tool-text-out-of-core.md` names `by_name/1` and `spec/1`. It is the record of an earlier design.
- Skipped: the `Map.new` from specs to the module map is in the session and in two tests. The two tests start the hands without a session.
- Skipped: `tool_modules` stays in the server state after `init`. It is one small map.

### Spec

- Fixed: `resume/2` ran `Session.File.resume/2`, which can repair a torn last line, before the spec check. The spec check now runs right after the `cwd` check in both `start/2` and `resume/2`. The resume test appends a torn line and checks that the file bytes do not change; it fails with the old order.
- Fixed: the `error_text/1` list in the feature doc now names `{:bad_tool_spec, label}` as an `inspect/1` fallback.
- Fixed: the stale `Hands.tools/1` row (same as Standards).
- Kept: duplicate names and the top-level key rule (see Decisions).

### Failure path

No reproduced finding. Probed through `Session.start/2`: every bad name, description, and parameters shape, and nested invalid bytes, are rejected. Observations: a raising callback raises in the caller (now in the feature doc); a nested map with both `"a"` and `:a` keys passes and encodes a duplicate JSON key, which is inside the documented top-level bound.

## Round 2 (full)

The fix: 17 changed lines in `lib/`, in two code files (`session.ex`, `tool.ex`). More than 15 lines and more than one code file: a full round.

- Simplify (one agent over the four angles): clean. Fixed: a `@doc` line that was too long was rewrapped.
- Standards: no hard violations. Skipped again: `:persistent_term` in an async test; the key belongs to one test and is erased.
- Spec: clean. No path breaks the invariant: before the spec check, `start/2` runs only `Id.new/0` and the `cwd` check, and `resume/2` only reads the `:sessions_dir` option and checks `cwd`.
- Failure path: the round 1 reproduction passes. One finding outside this diff, already on master: a tool whose `check/0` fails is rejected in `Hands.init/1`, after `resume/2` repaired the file or `start/2` created it, which leaves an orphan file. Not fixed here: `check/0` is not a spec callback, #142 does not name it, and the moduledoc of the hands documents it at hands start. Reported to the orchestrator for a separate ticket.
