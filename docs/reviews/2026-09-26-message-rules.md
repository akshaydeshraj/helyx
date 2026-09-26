# Review: the stop-reason set and the harness id rule move to `Helyx.Message` (#118)

Date: 2026-09-26. Base: `origin/master` at `e4f96d4`. Four rounds: round 1 complete, round 2 full, rounds 3 and 4 reduced.

The change moves the stop-reason set (`stop_reasons/0`, `t:stop_reason/0`) and the harness id rule (`harness_id?/1`) from `Helyx.Session` and `Helyx.SessionFile` to `Helyx.Message`. `Helyx.Session` takes `@stop_reasons` from `Message.stop_reasons()` at compile time. `Helyx.SessionFile` builds its encode and decode clauses from the set at compile time, and defines neither rule. `Helyx.Provider.stop_reason` is now an alias of `Helyx.Message.stop_reason`.

Invariant: `Helyx.Message` is the one owner of the stop-reason set and of the harness id rule. A message that the session file writes or reads has a stop reason in `Message.stop_reasons/0` or nil.

Bounds sensor output, every round:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (complete)

Simplify: four agents.

- Simplification: a comment in `session.ex` still named `SessionFile` as the owner of the set. Fixed.
- Altitude and reuse: `Helyx.Provider` wrote the set again as a type. Fixed: `Helyx.Message` defines `t:stop_reason/0`, and `Helyx.Provider` aliases it.
- `harness_id?/1` calls `String.valid?/1`, not `valid_utf8?/1`. For a binary the two are the same. Not changed.
- Efficiency: no findings.

| Axis | Findings | Resolution |
| --- | --- | --- |
| Standards | 0 hard, 4 judgement calls | 3 fixed, 1 rejected. See below. |
| Spec | 0 | None needed. |
| Failure path | 0 | Probes at 255, 256, and 257 bytes, with multibyte text, and all stop reason strings. All passed. |

Standards judgement calls:

1. The set was written twice in `Helyx.Message`, as a list and as a type. Fixed in round 2: the type is now built from the list at compile time.
2. Change the struct field to `stop_reason() | nil`. Rejected: a partial message in a `message_end` event has `:error` or `:aborted` (`close_partial_message/3` in `Helyx.Session`).
3. The moduledoc did not name the rules that the module now owns. Fixed.
4. "fails loudly" is an idiom. Fixed: "raises an error".

## Round 2 (full: the fix touched two code files)

Simplify: the altitude and reuse agents asked for the type to be built from the list, not kept in step by a comment. Fixed. The struct field point was rejected again, for the reason above.

| Axis | Findings | Resolution |
| --- | --- | --- |
| Standards | 1 hard, 1 judgement call | Fixed. |
| Spec | 0 | The derived type is `:end_turn \| :tool_use \| :max_tokens`, the same as before. |
| Failure path | 1 | Not changed in code. Documented. See below. |

- Standards: `docs/features/coding-agent.md` line 134 still said "The format owns a closed `stop_reason` set". Fixed. A comment line in `session.ex` was too long. Fixed.
- Failure path: `SessionFile.append_harness_session/3` checks only `is_binary(id)`. A caller can write an id that fails `Message.harness_id?/1`, and a later resume then rejects the whole file. Master has the same gap. No path reaches it: the only caller, `Helyx.Session`, checks the id first. The contract says that the caller checks. Not changed in code: a check on write changes the `SessionFile` contract, and this ticket only moves the rules. The `@doc` now names the rule (round 4). A person decides whether to file a ticket.

## Round 3 (reduced: a comment and a doc line)

| Axis | Findings | Resolution |
| --- | --- | --- |
| Spec | 1 | Fixed: the `@doc` of `append_harness_session/3` now names `Helyx.Message.harness_id?/1`. |
| Failure path | 1 | Fixed. See below. |

- Failure path: `decode_message/1` used `entry["stop_reason"] && decode_stop_reason(...)`. A file with `"stop_reason": false` resumed with `stop_reason: false`, outside the set. Master has the same bug. Fixed: nil has its own `decode_stop_reason` and `encode_stop_reason` clause, and every other value goes to the clauses built from the set. New test: "a stop reason of false is rejected" in `test/helyx/session_file_test.exs`.

## Round 4 (reduced: one code file, about 10 lines, no new function)

| Axis | Findings | Resolution |
| --- | --- | --- |
| Spec | 0 | None needed. |
| Failure path | 0 | 19 probes: `true`, `0`, `""`, case and whitespace variants, `[]`, `{}`, duplicate keys on read; `false`, `true`, `:aborted`, `:error`, a string, and `0` on write. All rejected or raised before the write. |

## Orchestrator

- The fix for a stop reason of JSON `false`: accepted. The defect is in the encode and decode path that this ticket changes, and the new test adds an assertion without a change to an existing one.
- No id check in `SessionFile.append_harness_session/3`: accepted for this ticket, because the check would change the caller's contract. Filed as #129.
- Codex adversarial review, round 1: approve, 0 findings.
