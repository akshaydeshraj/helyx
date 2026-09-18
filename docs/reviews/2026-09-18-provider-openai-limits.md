# Review: OpenAI provider input limits (issue #36)

Scope: `plugins/provider_openai` gets three named limits on network input — an SSE line (1 MiB), tool call bytes per response (10 MiB), and the HTTP error body (16 KiB) — plus rows in the bounds table of `docs/features/coding-agent.md`. `/ship` review record; every round ran as sub-agents.

## Round 1 (full: simplify, standards, spec, failure path)

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 1.1 | simplify | The line limit was enforced twice: a guard in `line/2` and a post-reduce `case` in `handle/2` | Fixed: `split_lines/1` promotes an over-limit partial to a complete line; one guard remains |
| 1.2 | simplify | `arguments_bytes/1` walked `tool_calls` a second time next to `add_call_delta/2` | Fixed: the counter rides the existing reduce |
| 1.3 | simplify (reuse) | `binary_part/3` on the error body can cut mid-character; a boundary helper exists in core | Fixed locally; later replaced by `String.replace_invalid/2` (2.4) |
| 1.4 | simplify | The test's SSE line template was written twice, so the byte math could drift | Fixed: one literal, `content_line_of/2` derives the padding |
| 1.5 | standards, spec | No multibyte test at any limit (`review-checklist.md`, "Specs and bounds") | Fixed: multibyte at/over tests for all three limits |
| 1.6 | failure path | Tool call ids and names were retained but not counted; 27 MB of names passed uncharged | Fixed: ids and names count into the same budget |
| 1.7 | failure path | The truncation marker could overstate the cut after a boundary retreat | Fixed: the marker names the limit, not the cut size |
| 1.8 | spec | The doc rows read `bytes` where the payload is the limit; the citation clause and the one-chunk overshoot were unstated | Fixed: rows say `limit`, the no-citation note and overshoot caveats are explicit |
| 1.9 | simplify (reuse) | `@max_tool_call_bytes` copies `Helyx.Tool`'s private `@max_file_bytes` | Skipped: no public accessor exists, a core API addition is out of ticket scope, and 1x the file limit is the wrong multiple once JSON escaping counts |
| 1.10 | simplify | Fewer, larger argument fragments in tests | Skipped: the 1 MiB line limit forces fragments under ~1 MiB, so a 10 MiB total needs many |
| 1.11 | simplify (reuse) | Test files re-declare the limit literals | Skipped: drift fails loudly because the error tuples carry the source limit |
| 1.12 | simplify (altitude) | A session-level byte cap on all deltas would be the general fix | Skipped: ticket #36 defers flow control explicitly |

Fix diff: two code files touched, functions added and removed, so the rerun was a full round.

## Round 2 (full)

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 2.1 | standards, spec | A repeat delta with an empty fragment consed a list cell at zero charge, so `calls` grew unbounded | Fixed at the mechanism (second finding on it): a zero-charge delta retains zero bytes |
| 2.2 | spec | Non-binary ids, names, and indexes were retained but uncharged (`bin_size/1` returns 0) | Fixed at the gate: `valid_call?` types every retained field; non-binary ones are `bad_chunk` |
| 2.3 | simplify | The byte counter re-fetched `id` and `name`; the reduce carried tuple ceremony | Fixed: the reduce threads `acc`; fields bind once |
| 2.4 | simplify (reuse) | `on_char_boundary/2` re-implemented the boundary retreat; `String.replace_invalid/2` is the stdlib form the repo already uses | Fixed: `replace_invalid` on the cut, helper deleted |
| 2.5 | simplify (reuse) | A third truncation marker wording | Fixed: bracketed `[truncated at the N-byte limit]`, matching the repo's marker family |
| 2.6 | simplify | `drain/1` rebuilt the body binary per chunk | Fixed: iodata plus a running count, one materialization |
| 2.7 | simplify (altitude) | `args_bytes` and `:tool_arguments_over_limit` no longer named what they count | Fixed: renamed `tool_bytes`, `@max_tool_call_bytes`, `{:tool_call_bytes_over_limit, limit}` |
| 2.8 | standards | `finish` and `usage` retained uncharged | Resolved by comment: overwritten per chunk, bounded by the line limit |
| 2.9 | standards | `plugins/tool_bash` `keep_tail/1` cuts mid-character; core keeps its 12-line boundary helper that `String.replace_invalid/2` replaces | Out of this diff, pre-existing. Follow-up filed as #51 |
| 2.10 | simplify | `on_char_boundary` validity scan was O(n) where O(1) suffices | Skipped, then mooted by 2.4 |
| 2.11 | failure path | Bignum JSON integer as `index` retained ~374 KB as a map key, charged 100 bytes | Fixed: integer indexes capped at `@max_call_index 10_000`; over it is `bad_chunk` |

The bignum fix changed under 15 lines in one file with no new function: reduced round.

## Round 3 (reduced: spec, failure path)

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 3.1 | spec | One-byte fragments charged 1 byte but retained ~32 bytes of cons cells (~40x amplification) | Fixed: `@call_fragment_bytes 32` flat charge per non-empty fragment |
| 3.2 | failure path | None; prior reproductions verified fixed at exact boundaries | — |

The fragment-charge fix changed under 15 lines in one file with no new function: reduced round.

## Round 4 (reduced: spec, failure path)

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 4.1 | spec | Retained fields are sub-binaries that keep their whole decoded SSE line alive: 33 charged bytes could retain ~1 MiB per line | Fixed: `copy/1` (`:binary.copy`) on every retained field, so the charge states true retention |
| 4.2 | failure path | None; fragment-spray arithmetic verified exact (trips at charge 10_485_761, not at 10_485_760) | — |

The copy fix added a function: round 5 was a full round.

## Round 5 (full)

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 5.1 | simplify | `copy/1` on the reuse, placement, and ceremony angles | Clean; the wrapper earns its keep |
| 5.2 | simplify | The efficiency and simplification agents proposed opposite charging policies (exact retention vs. unconditional upper bound) | Skipped both: the verified code sits between them, and either rewrite re-opens verified boundaries for style |
| 5.3 | simplify | The retention comment said "SSE line" where the pinned parent is the whole coalesced chunk | Fixed: comment corrected |
| 5.4 | standards, spec, failure path | `finish` and `usage` retained decoded wire terms uncopied and uncharged, pinning the coalesced chunk until `[DONE]` (reproduced: 19 MB via a 100-byte `finish_reason`) | Fixed at the mechanism (third sub-binary finding): both normalize at ingest to an atom and an integer map, so the accumulator retains no wire bytes |
| 5.5 | standards | A never-supplied call id shipped as `nil` against `ToolCall`'s `String.t()` type | Fixed: `""` sentinel, symmetric with `name` |
| 5.6 | spec | `@call_fragment_bytes 32` undercounted measured retention (~56 bytes per kept fragment) | Fixed: 64 |
| 5.7 | spec | The tool-budget row lacked its one-line overshoot caveat | Fixed in the doc row |

The 5.4 fix crossed 15 lines and the two-findings rule applied, so round 6 was a full round; its simplify pass ran as one four-angle agent over the ~20 changed lines.

## Round 6 (full)

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 6.1 | simplify | `finish_reason` fetched twice with `&&`/`\|\|` next to an `if` of the same shape | Fixed: both fields bind once, symmetric `if` |
| 6.2 | simplify | The acc map rebuild on text-only chunks | Skipped: parity with the pre-change code, not introduced waste |
| 6.3 | standards, spec | Clean; one comment stated only the small-fragment case behind the 64-byte charge | Fixed: comment wording only, no logic |
| 6.4 | failure path | None. The 19 MB pinning reproduction retains 0 bytes after the fix; wrong-typed `finish_reason` and `usage` neither crash nor retain; 40 tests green | — |

The 6.3 resolution changed comment text only, so no further round ran.

Precommit's Dialyzer flagged the improper-list cons in `drain/1` (`[body | chunk]` with a binary tail); the fix builds a proper list, `[body, chunk]`, with identical iodata semantics. Two lines, one file, no function change.

## Verification

- Reproductions ran in sub-agent scratch tests at exact boundaries: the line limit at 1_048_576 and one over (multibyte included), the tool budget tripping at charge 10_485_761 and not at 10_485_760, fragment spray at the predicted delta count, and retained memory near zero against multi-megabyte pinning inputs.
- `plugins/provider_openai`: 40 tests, 0 failures. `mix precommit` at the root: see the commit.

## Follow-ups outside this diff

- #51: `plugins/tool_bash` `keep_tail/1` cuts the kept tail mid-character, and `lib/helyx/tool.ex` keeps `on_boundary/3` and `drop_edge/2` where `String.replace_invalid/2` suffices (2.9).
- Session-side accumulation of emitted deltas stays unbounded by design until the flow-control work (#36 defers it).
