# Review: bound the heap of the session file decode (#64)

The change runs the read and the decode of `SessionFile.resume/3` in their own process under `:max_heap_size` of 1 GiB, as the Decision on #64 chose. A file whose decode passes the cap gives `{:too_large, text}`, and the text says to start a new session.

Bounds sensor, both rounds: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

## Measurements

Resume under the default cap, on the branch, 2026-09-25:

| File | Size | Time | Result |
| ---- | ---- | ---- | ------ |
| valid header, then 60 MiB of `[` | 62,914,696 B | 2.5 s | `:too_large` |
| valid header, then an array of 15 Mi `0,` | 31,457,419 B | 1.6 s | `:too_large` |
| valid header, then 60 MiB of `{"type":"x","id":"a"}` lines | 62,914,679 B | 2.8 s | `:too_large` |
| 6,000 text-heavy messages | 66,914,814 B | 0.5 s | resumes |
| 153-byte one-word user messages, 48 MiB | | 2.6 s | resumes |
| 153-byte one-word user messages, 63 MiB | 66,060,437 B | 2.3 s | `:too_large` |

The last row is a valid session under the file limit that the cap rejects. It needs about 430,000 one-word messages in one session. It is recorded in the bounds table.

## Round 1: simplify, standards, spec, failure path

Simplify: no fix applied. Skipped: move `repair/3` into the parse process (a heap kill after the repair would mutate a file that the caller then rejects); build the messages during the walk to lower the peak heap (a change to the parse mechanism that the Decision did not ask for; recorded as the measured row above); a follow-up for the same decode growth in `plugins/bundled/lib/helyx/provider/openai.ex` (outside #64).

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | `max_heap_bytes` under 8 turns the cap off (0 words); values under the minimum heap raise `ArgumentError` from `spawn_opt`. Reproduced with 1 MiB of `[`. | The guard has a floor of 1 MiB. Tests: 8 and 1 MiB - 1 raise; 1 MiB and 1 GiB resume. |
| Standards | `load/3` returned a bare map of a known shape (AGENTS.md: structs over bare maps). | `load/3` returns `{:ok, %Resumed{}, {kept_bytes, tail}}`. |
| Standards, spec | No test at the limit of the heap cap. | A byte-exact heap test is not practical. Tests at the guard edges, and one test that a 63 MiB text-heavy session resumes under the default cap. |
| Spec | A real session near the file limit must fit; 63 MiB of one-word messages does not. | Recorded in the bounds table; reported to the user. Not changed. |
| Spec | A kill from outside the parse process gives the heap-cap text. | Accepted: nothing else knows the pid. |
| Spec | Two resumes at once can hold 2 GiB. | Accepted: one resume runs at each start of the agent. |
| Standards | ADR 0004 says link work to its owner; the parse process is only monitored. | Accepted and stated in the ownership table: a link carries the heap kill to the caller. |
| Standards | Repeated `16 * 1024 * 1024` and a hardcoded word size in the tests. | Not changed: the existing test beside it uses the same form. |

Fix diff: 33 lines in one code file, the return shape of `load/3` changed. Full round.

## Round 2: simplify, standards, spec, failure path

Simplify: the floor became `@min_heap_bytes`, and the `@doc` states it. Skipped: a smaller file for the text-heavy test (the test checks the claim in the bounds row at the real size; it runs in under 1 s).

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Standards | None. The tuple `{kept_bytes, tail}` is a judgement call. | Kept: only `repair/3` reads it. |
| Spec | The floor of 1 MiB fails on a VM started with a minimum heap over 1 MiB (`+hms`). | The comment on `@min_heap_bytes` states it. The option exists for tests only. |
| Spec | `Session.resume/2` can reject a saved model after `SessionFile.resume/3` repaired the file. | Out of scope: on master before #64; the bounds row claims the rule for `{:too_large, text}` only. Reported to the user. |
| Spec | The row said the transcript is copied once; it passes the session supervisor to the session process. | The bounds row states the copies: caller, supervisor (not kept for a temporary child), session. |
| Failure path | None reproduced. The reproduction of round 1 now raises at the guard; at the floor and above it the cap rejects, and the file stays byte-identical. | — |

Fix diff: a comment of 2 lines in one code file, and the bounds row. Reduced round.

## Round 3, reduced: spec, failure path

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | Both round 2 statements are true (`+hms` counts words; the supervisor drops the arguments of a temporary child). | — |
| Spec | The doc line "a client renders from the restored transcript" is false: no client can read the restored transcript. | Out of scope: on master before #64; reported to the user. |
| Spec | Each turn copies the transcript into a provider Task with no heap cap. | Out of scope: compaction bounds the transcript (#1). |
| Failure path | The session supervisor keeps the start message as garbage until it allocates again: 226 MB in the supervisor after a resume of a 48 MB file of 300,000 one-word messages; a forced GC frees it. The row said "for a moment". | The bounds row states the retained copy as open, on master before #64. A fix (the session reads the file in its own `init`, or a GC after the start) changes the start path of `Helyx.Session`, outside #64; reported to the user for a ticket. |

The round 3 fix is Markdown only, so no further code round.
