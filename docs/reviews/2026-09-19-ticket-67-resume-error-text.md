# Review: ticket #67, the resume error prints as a tuple

Date: 2026-09-19. Branch `ticket/67-resume-error-text`, base `origin/master` at `ad39e59`.

Invariant: a start or a resume of `mix helyx` that fails prints exactly one line on stderr, `could not start the agent: <sentence>`, and exits with a non-zero status. `CodingAgent.error_text/1` makes the sentence. It never raises. It returns one line of valid UTF-8 with no control character. Every error that `Helyx.SessionFile.resume/3` returns has a clause, so it prints as a plain sentence and not as a tuple. The `:too_large` text of `Helyx.SessionFile` prints unchanged.

Documented exceptions:

- An error with no clause prints through `inspect/1`, so it can show as a tuple: a duplicate tool name, a supervisor error, a session that died.
- A value from the file (`:unknown_version`, the type of a bad entry, a provider id) prints through `inspect/1`. A JSON object shows as a map, with `{`.
- The line has no hard cap on its length. The longest line measured is about 16.5 KB.
- The clean pass also applies to the `:too_large` text. The text that `Helyx.SessionFile` makes has nothing to clean, so it prints unchanged.
- `:not_regular` and a bare POSIX atom have a unit test only. At the task boundary, a file that cannot be read fails the header scan first, and the result is `:not_found`.

## Simplify, round 1

Four agents: reuse, simplification, efficiency, altitude.

- Simplification, efficiency, altitude, applied: the task tests moved to `test/mix/tasks/helyx_test.exs` with `async: false`. `CodingAgentTest` stays async.
- Efficiency, not applied: replace the sparse 64 MiB file with a unit assertion. The ticket wants the `:too_large` case at the task boundary, and `Helyx.Session.resume/2` must not get a `:max_bytes` option in this ticket.
- Reuse, not applied: the test repeats the limit `67_108_864`. `Helyx.SessionFile` has no public accessor, and the ticket does not change that module.

## Round 1, complete round

Bounds sensor, base `origin/master`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 1.1 | spec | The rescue in `resume/3` puts an exception message of many lines in `{:invalid_file, text}`. Reproduced with a `message` entry that has no `content` | Fixed: whitespace runs become one space. Task test added |
| 1.2 | spec, standards, failure-path | The atom clause took every atom, so `:queue_full` printed as `unknown POSIX error: queue_full` | Fixed: an atom that is not a POSIX code prints through `inspect/1` |
| 1.3 | failure-path | A saved model ref that is not valid printed `{:invalid_model_ref, "nope"}` on resume | Fixed: clauses for the model ref and the provider errors. Task test added |
| 1.4 | failure-path | `{:repair_failed, reason}` raised for a reason that is not an atom | Fixed: the reason goes through the same clauses |
| 1.5 | standards | No clause for `{:create_failed, _}` | Fixed: clause added |
| 1.6 | standards | A doc sentence held four ideas; `error()` must be `error/0`; two test comments gave the same reason | Fixed |
| 1.7 | spec | `:not_regular` and a bare POSIX atom have no test at the task boundary | Not applied: see the documented exceptions |

## Round 2, full round

The fix: 40 lines in one code file, with new clauses. Simplify ran with two agents that covered the four angles (reuse and efficiency; simplification and altitude). Sensor: skipped, as above.

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 2.1 | simplify (altitude) | Put a `format_error/1` next to the type in `Helyx.SessionFile` | Not applied: the worker scope keeps `Helyx.SessionFile` unchanged, and the `--resume` hint is product text. An option for a later ticket |
| 2.2 | simplify | The doc lists the clauses | Not applied: the feature doc is the precise record |
| 2.3 | spec | An empty `PATH` printed `{:tool_unavailable, "bash", "perl not found: ..."}`. Reachable | Fixed: clause added |
| 2.4 | standards | `{:ambiguous_provider, id}` had no clause; the `@doc` first sentence had no verb | Fixed |
| 2.5 | failure-path | `{:too_large, text}` and `{:invalid_file, text}` passed control characters and bad UTF-8; an `Inspect` implementation that raises gave about 20 lines. No producer reaches these today | Fixed at the mechanism: one clean pass over every sentence |
| 2.6 | author | An invalid model ref of a saved file has no bound before the parse | Fixed: the ref stays out of the sentence, as in the TUI notice |

Findings 1.3 and 2.3 are both a tuple from the `inspect/1` fallback. The fallback cannot make a sentence for a shape that it does not know. The mechanism fix is the documented exception plus a clause for each shape that a review reached.

## Round 3, full round

The fix: about 35 lines in one code file, `error_text/1` split into a public function and private `sentence/1`. Simplify ran as one agent with four angles. Sensor: skipped.

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 3.1 | simplify | `@tag :tmp_dir` seven times | Fixed: `@describetag` |
| 3.2 | simplify (reuse) | The TUI `model_error/1` has other words for the same errors | Not applied: it is private and in the optional TUI block |
| 3.3 | standards, spec | `{:create_failed, :invalid_utf8}` printed `:invalid_utf8` | Fixed: clause added |
| 3.4 | standards | Two passive sentences in the `@doc` | Fixed |
| 3.5 | spec | With no terminal the task printed `{:terminal_init_failed, "..."}`. Reachable | Fixed: clause added |
| 3.6 | spec | A JSON object as an entry type or a version shows as a map | Documented |
| 3.7 | spec | No bounds row for the error line | Fixed: row added |
| 3.8 | failure-path | About 55 inputs; none broke the invariant | None |

## Round 4, reduced round

The fix: 5 lines in one code file, two new clauses of a private function, no new function. Spec and failure-path agents. Sensor: skipped.

| # | Axis | Finding | Resolution |
|---|---|---|---|
| 4.1 | spec | The measured line length in the bounds row was too low: 16,452 bytes, not 4.4 KB | Fixed in the doc. Markdown only |
| 4.2 | failure-path | `{:repair_failed, _}` nested 100,000 deep takes 6 s. `Helyx.SessionFile` nests one level | Not applied: no producer |
| 4.3 | failure-path | `{:too_large, ""}` gives an empty sentence | Not applied: the one producer makes a fixed sentence |
| 4.4 | failure-path | About 75 inputs and the real task with no terminal; none broke the invariant | None |

No code changed after round 4.
