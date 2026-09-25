# Review: the Claude Code harness provider (#10)

The ticket ships in two commits. Commit 1 moves the watchdog of the bash tool into the helper module `Helyx.Watchdog` (with `Helyx.Watchdog.Group`), so the bash tool and the provider share it, and gives it a counted input on stdin. Commit 2 adds the provider.

## Commit 1: the shared watchdog

Bounds sensor, all rounds: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

### Round 1: simplify, standards, spec, failure path

Simplify applied: `close/1` is private again; stdin is read 65,536 bytes per call, not 4,096; `AGENTS.md` "Module naming" states that a helper module such as `Helyx.Watchdog` is not an interface (altitude item 3). Skipped:

- One delegate less (`Bash.release` to `Watchdog.release` to `Watchdog.Group.release`): `Helyx.Watchdog.release/3` is the one entry both plugins name, so `Group` stays internal.
- Move the start report into `Helyx.Watchdog` and stop returning `nonce` and `go`: the provider reads its stream in a `Stream.resource`, not by a collect loop, and skips the start line as a non-JSON line; only the bash tool parses the report. Revisit if a third caller needs it.
- Drop the input path until the provider lands: commit 2 of the same ticket uses it.
- Rename the rows "bash watchdog marker read" and "bash command start after the group marker": older review records and devlogs cite them by name.
- `Helyx.Id.new/0` for the nonce: the line was already in the bash tool, and the nonce scheme should not follow the id scheme of core.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Standards | Tests of `Helyx.Watchdog.read_marker/4` and `launcher/4` stay in the bash test files (tests mirror `lib/`). | The describe block "the preamble limit of the marker read" moved to `test/helyx/watchdog_test.exs`. `bash_preamble_test.exs` stays: it tests the bash tool with a hostile preamble. |
| Standards, spec | The input bound says "the caller bounds" with no number. | Commit 2 states the replay cap in the row. The bash tool passes no input. |
| Standards | No test with input shorter than the count. | Test "input shorter than the count: a closed port still kills the group". |
| Standards | `Helyx.Tool.Bash.OSHelpers` is no longer bash-specific. | Renamed `Helyx.Test.OSHelpers`. |
| Standards | `Helyx.Watchdog` has the shape of an interface name. | The `AGENTS.md` line states the exception. |
| Standards | `{:started, port, pre, nonce, go}` is a data clump; `-1` as "no input" is a primitive. | Kept: see the simplify skip above; `-1` is internal to the perl argument. |
| Spec | Stale references: `tool-resource-release.md` lines 54, 56, 80, 87, and the `coding-agent.md` row "watchdog process". | Each now names `Helyx.Watchdog`, `Helyx.Watchdog.Group`, or `Helyx.Watchdog.start/3`, with "#10". |
| Spec | The `AGENTS.md` rule was not asked for. | Kept: simplify asked for it, and it states the naming rule the ADR 0005 revision needs. |
| Spec | The ADR revisions describe the provider, which is not in this commit. | Commit 2 adds it on the same branch. |
| Spec | The provider must show that its hold lands: `Helyx.Tool.hold/1` does nothing outside the hands. | Commit 2 runs the provider stream as a Task of the hands, with a test. |
| Failure path | None reproduced. Probes: input of 0, 1, 65,535, 65,536, 65,537 and 3,000,000 bytes; multibyte, NUL, and a line that looks like the go-ahead; nil input reads `/dev/null`; `head -c 3` on 3 MB; a bad directory and a failed exec with input; 50 MB to a command that does not read (group gone 1 s after the close); the owner killed during `start/3`. | Not probed: the watchdog holds the input in memory, so its bound depends on the caller of commit 2. |

Fix diff: test moves and one new test, a test helper rename, and Markdown; 0 lines of code outside tests and Markdown. Reduced round.

### Round 2, reduced: spec, failure path

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | The rows "command port" and "bash watchdog marker read", ADR 0004 line 17, and the `@moduledoc` of the bash tool still say the bash tool opens, holds, and closes the port. | Each names `Helyx.Watchdog.start/3` or `Helyx.Watchdog`. |
| Spec | No test calls `start/3` with an input, and none with multibyte input. | Test "start/3 counts the input in bytes, multibyte included" (8 characters, 11 bytes). |
| Spec | The under-count test sits outside `describe "input (#10)"`; the comment of `Helyx.Test.OSHelpers` names only the bash tool. | Moved into the describe, and its helper `await_text` removed; the comment names both. |
| Spec | `bash_preamble_test.exs` calls `Helyx.Watchdog` from under `tool/`. | Kept: it is `async: false` because it changes the environment of the bash tool. |
| Failure path | When the command started by `exec` exits, the watchdog exits and closes the input pipe, so a background job that still reads the inherited stdin gets end of file after part of the input (65,533 of 3,000,000 bytes). | Accepted hole, stated in the bounds row "watchdog input on stdin": the release KILLs the group at delivery, and the reader of the provider is the command itself. |

Fix diff: 12 lines of `@moduledoc` in one code file; tests and Markdown. Reduced round.

### Round 3, reduced: spec, failure path

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | None. The claims of the row "watchdog input on stdin" match the perl script; a probe confirmed that the KILL at delivery reaches a held group after the command started by `exec` exits. | — |
| Failure path | None against this diff. Probes: the accepted hole through the real hands (bash tool, and a scratch tool with 3,000,000 bytes of input); exact bytes for input of 1, 65,535, 65,536, 65,537, 131,073, and 1,000,001 bytes after a newline, a NUL, and `é`; an abort with 5 MB of input and a suspended Task for a command that does not read and one that ignores TERM. | Noted, not from this diff: a command that STOPs its watchdog makes an abort take 10.6 s and log `abort cleanup failed`, as the bounds row "wait for a killed process group" states. |

Precommit then failed on Dialyzer: `improper_list_constr` at the go-ahead write `[go, "\n" | input || ""]`. The fix is `[go, "\n", input || ""]`, the same bytes. Fix diff: 1 line in one code file. Reduced round.

### Round 4, reduced: spec, failure path

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | None. No doc states an iodata input or a write shape. | — |
| Failure path | None. `wc -c` counted exactly 0, 0, 4, and 3 bytes for nil, `""`, `"\nab\n"`, and `<<0, 10, 0>>`. An iodata input raises in `byte_size/1` before `Port.open`, as before the fix; the comment of `start/3` states a binary. | — |

Precommit: passed.

## Commit 2: the provider

Bounds sensor, all rounds: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

### Round 1: simplify, standards, spec, failure path

Simplify applied: the kind of the provider is computed once per turn and kept in `Turn.kind`; the stop-reason check of `done` and `message_end` is one function, `capped_usage/1`, with one `@stop_reasons`; `close_assistant/3` returns the message, so `end_turn/2` does not walk the transcript again; `resumable/2` parses the model ref with `ModelRef.parse/1`; the provider calls `Helyx.Watchdog.close/1` in place of its own copy. Skipped, with the reason:

- Send every provider stream through `Helyx.Hands.stream/4`, or give `spawn_task/5` a reply function: the ticket decided that only a harness stream is a Task of the hands, so a model stream is never refused while a handle is unconfirmed.
- One behaviour for `hold` and `release`, shared by `Helyx.Tool` and `Helyx.Provider`: outside this ticket; `Helyx.Provider` cites the contract of `Helyx.Tool.release/3`.
- A stderr option on `Helyx.Watchdog.start/3` in place of `/bin/sh -c 'exec ... 2>/dev/null'`: a change of the shared perl launcher for one caller.
- The start report of the bash tool moved into `Helyx.Watchdog`: the same skip as in commit 1.
- `Helyx.Tool.truncate(text, :tail)` for the program's error text: an error reason is not a tool result; the 2,000-byte cut stays, with its own bounds row.
- The transcript copied into the hands, then into the Task; the replay encodes the whole history before the cap: one copy and one pass per harness turn, linear in a transcript the session already holds.
- `lost` in the provider event, a `restart_fresh` helper, one clause for `stop/1`, and a flat view-model clause: no change in size or clarity.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Standards | The run state of the provider is a bare map of 12 known keys, and so is the run. | Private structs `ClaudeCode.State` and `ClaudeCode.Run`. |
| Standards | The comment says an entry is `{line or nil, ...}`; the value is `false`. | Comment fixed. |
| Standards | `keep/2` does not say what it keeps. | Renamed `cap_replay/2`. |
| Standards | `Helyx.Watchdog.close/1` has a `@doc` string in a `@moduledoc false` module. | `@doc false` with the comment, as the other functions. |
| Standards | The `@doc` of `Helyx.Provider.kind/1` is not clear; "SessionFile owns the set" is not true. | Both texts fixed. |
| Standards | Repeated switches on `turn.kind`; `release/3` copied from `Helyx.Tool`; `:stream` as a sentinel id in the hands; `:lost` in `terminal`; the name `j/1` in the test. | Kept: the ticket decided one behaviour with an optional `kind/0`; the other items are the simplify skips above or local to one function. |
| Spec | No test at the limit of the 256-byte id, of the replay cap, or of the line cap; no session test of a bad harness event or of a dropped result. | Tests: ids of 256 bytes (multibyte), 257 bytes, 0 bytes, and invalid UTF-8; history of exactly 400,000 bytes and one byte more; a line of exactly 16 MiB; a result for no completed call. |
| Spec | The 2,000-byte cut of the error text has no bounds row. | Row "Claude Code error text". |
| Spec | Tool calls and messages of a harness turn have no bound other than the line cap. | Row "Claude Code tool calls and messages per harness turn": accepted, like the provider calls of a model turn. |
| Spec | The row "session to hands calls" does not name `Helyx.Hands.stream/4`. | Row updated. |
| Failure path | A model provider that sends `message_end`, `tool_result`, or `harness_session` gets them accepted: its tool call gets an `aborted` result and never runs, and an empty assistant message joins the transcript (reproduced with a scratch provider). | `consume/4` takes the kind and accepts the three events only from a harness; a model provider fails the turn with `{:bad_stream_event, event}`. Test "a model provider that sends a harness event fails the turn". |
| Failure path | The 2,000-byte cut gives 2,002 bytes when it lands in a character (`String.replace_invalid/1` puts in U+FFFD). | The half character is dropped (`String.replace_invalid(text, "")`). Test with `"a" <> 1,000 × "é"`: 1,999 bytes, valid. |

Fix diff: 69 lines in 4 code files, with two new structs. Full round.

### Round 2, full: simplify, standards, spec, failure path

Simplify applied: the parameter of `consume/4` is `harness?`, so it no longer shares the name `kind` with the tag of the delta clause; the id tests are one test for the kept id and one loop for the rejects; the replay test encodes with `j/1`. Skipped: one list of stop reasons shared by `Helyx.Provider`, `Helyx.Session`, and `SessionFile`, because the three copies are older than this ticket.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path, spec | `kind/0` runs unchecked in the session process: `:bogus` stops the session with a `FunctionClauseError` in `start_stream/3`, and a raise in `kind/0` stops it in `begin_turn/2` (reproduced). | The second finding on "a plugin value is checked before it reaches the session", so the check moves to where a provider is resolved: `Helyx.Provider.find/2` accepts only `:model` or `:harness` and rescues a raise, in the caller of start, resume, and switch, with `{:error, {:bad_provider_kind, id}}`. Test "a provider kind other than :model or :harness is refused at start and switch". |
| Failure path, spec | The `cut` of `{:harness_session, id, cut}` has no digit cap: a cut of 50,001 digits reached the event and the TUI (reproduced). | `harness_event/1` rejects a cut that `Message.cap_integers/1` changes, the same digit limit as every other integer from a provider. Test model `big_cut`. |
| Failure path, spec | The `subtype` of the error has no bound: 1,000,000 bytes reached the terminal error (reproduced). | The subtype gets the same 2,000-byte cut; a subtype that is not a string is empty. Row "Claude Code error text" updated. |
| Spec | The error text has tests only over the limit; the id has no test at 1 byte. | The error test runs 1,999, 2,000, 2,001 bytes, and the multibyte case, for the text and the subtype; model `id1`. The text of the watchdog when the program did not start is not tested again here: the preamble limit of `Helyx.Watchdog.read_marker/4` bounds it first (commit 1 tests). |
| Standards | The row "tool calls and messages per harness turn" names no ticket. | The row says "unbounded, and accepted with no ticket", the words of the row "bash command start after the group marker". |
| Standards | `cap/1` and `cap_replay/2` cut different things. | `cap/1` is `cap_error/1`. |
| Standards | `next/1` matches bare maps, not `%State{}`; the replay entry is a 3-tuple; four booleans. | Kept: private to one module and small. |

Not changed: `provider.id()` still runs in the session process (`resumable/2`, the `harness_session` handler). `find/2` called it in the caller and got the id the ref names, so only an `id/0` that changes its answer can fail there.

Fix diff: 42 lines in 3 code files, a new function and a new error in the spec of `find/2`. Full round.

### Round 3, full: simplify, standards, spec, failure path

Simplify applied: the kind check moves out of `find/2`. `Helyx.Provider.kind/1` returns `{:ok, kind}` or `:error` and catches a raise; `resolve_model/2` calls it once, in the caller of start, resume, and switch, and the session keeps `State.kind`, so no turn calls `kind/0` again (altitude). `Helyx.Test.BadKind` has no unused setting. Skipped: a check of `kind/0` when `Helyx.Core` registers the plugin, because the core checks behaviours only and an optional callback of one interface does not belong there; `cut <= length(messages)` in place of the digit check, because a wrong small count only makes a wrong notice; one cap of error reasons in the session for every provider, because it changes the OpenAI provider too.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path, spec | `provider.id()` runs in the session process (`resumable/2`, the `harness_session` handler); an `id/0` that raises there stops the session (reproduced). | The third finding on "plugin code runs in the caller, not in the session", so the session now calls no plugin callback for metadata: it uses `turn.model.provider`, the prefix that `find/2` matched to `id/0` in the caller. `kind/1` catches a throw and an exit too. |
| Failure path, spec | A harness id from the file skips the 1..256-byte check: a resumed id of 1,000,000 bytes reached `--resume=` (reproduced). | The second finding on the id check, so the check is one function, `harness_id?/1`, for both entry points: the stream event and `resume/2`, which drops a stored id that fails it. Test "a stored id outside 1 to 256 bytes is dropped at resume, and the turn starts fresh". |
| Spec | A line over 16 MiB whose newline is in the same port chunk passed the cap (reproduced with a 16,777,300-byte line in one write). | One clause checks the part before the newline in both cases. Test "a line one byte over 16 MiB with its newline in one write is an error". |
| Spec | The render path of the error text is not stated. | The row states the `inspect/1` limits of the TUI, measured. |
| Spec | No test one under the replay cap or the line cap; no test of the kind on resume. | Replay at 399,999 bytes; lines of 16,777,215 and 16,777,216 bytes; test "a provider kind that raises is refused at resume". |
| Standards | The test "harness session ids of 1 and 256 bytes are kept" covers only 1 byte. | Renamed. |
| Standards | `ref`, `provider`, and `kind` travel together. | Kept: three values, one private function builds them. |

Fix diff: 36 lines in 3 code files, a new function. Full round.

### Round 4, full: simplify, standards, spec, failure path

Simplify applied: the harness id rule moves into the file format, `SessionFile.harness_id?/1`: resume rejects an entry that fails it as a malformed file, the file's policy for every entry the writer never produces, and `harness_event/1` calls the same function; the resume filter of round 3 is gone (altitude). `resumable/2` finds the last assistant message with one fold, not a reversed copy (efficiency). Skipped: the guard for an `id/0` that raises in `find/2`, older than this ticket and in the caller; one line splitter for both providers, whose splitters differ in CRLF and buffering.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | Each data chunk after the `result` line started a new 5 s exit wait: output once a second held the stream for 20 s (reproduced). | One deadline, set with the terminal; `next/1` waits for the time left. Row "Claude Code exit wait". |
| Failure path | Output after a success `result` still counted against the line cap: 17 MB after the result turned the `done` terminal into `line_over_limit` (reproduced). | `lines/2` reads nothing once the terminal is set. Test "output after the result is not read, and the exit wait runs once from the result". |
| Failure path | The `provider` key of a `harness_session` entry is checked only as a string (reproduced with 1,000,000 bytes, empty, and a space). | Not changed: the key is only compared with the provider prefix of a parsed ref, so a key that no ref can have is never read; the `model` of a model change has the same file check, and `ModelRef.parse/1` checks it on use. |
| Spec | No test one byte under the id limit. | 255 bytes is kept on resume, next to 256. |
| Spec | A malformed harness event puts the whole event in `{:bad_stream_event, event}`, up to the 16 MiB line. | Not changed: every provider's malformed event has carried the event since the stream check began; the TUI render is bounded by the `inspect/1` limits in the row "Claude Code error text". |
| Spec | `find/2` calls `id/0` with no guard. | Not changed: older than this ticket, and it runs in the caller. |
| Standards | `_kind` in the `catch` of `kind/1` looks like the local `kind`. | Renamed `_class`. |
| Standards | The capture with `if` in `resumable/2` is dense. | A two-clause `fn`. |

Fix diff: 31 lines in 3 code files, a new function. Full round.

### Round 5, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify applied: one function, `ended/2`, sets the terminal and the exit wait together, so the `not_started` path with an open port gets the 5 s wait too, not `:infinity` (altitude). `resumable/2` reads the stored id first and walks the transcript only when one exists, with a `with` and a helper `last_assistant/1` (efficiency, simplification). Skipped: an application env key for the exit wait so that the exit-wait test runs faster, because it adds configuration for a value that never changes; one shared deadline helper with `Helyx.Hands`, because the copy is one line.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | The exit-wait bound is in two rows, and neither names the `not_started` path that now sets a deadline. | One row, "Claude Code exit wait", names both terminals; the row "Wait for the program" is gone. The comment on `@exit_wait_ms` names both. |
| Spec | No test runs the `not_started` path and its 2,000-byte cut. | Test "a program that does not start ends the stream with its text cut at 2,000 bytes", with a working directory that does not exist. |
| Failure path | No break of the five invariants. Observation: a program that exits with no `result` line while a background child keeps stdout open holds the stream until the child ends (15 s with `sleep 15`), and the row said the wait before the result is the program's own loop. | Accepted, and the row now states it: the abort of the user bounds the wait before the result. |
| Standards | The comment on `ended/2` says every terminal path sets the wait, but the paths that end at once do not. | Renamed `await_exit/2`; the comment says every terminal that waits for the exit sets its deadline there. |
| Standards | `stored when stored != nil <- Map.get(...)` in `resumable/2`. | `{:ok, stored} <- Map.fetch(...)`. |
| Standards | `@harness_id_max_bytes` lost the reason for 256. | The comment is back. |

Fix diff: 16 lines in 3 code files. Full round.

### Round 6, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify applied: the `not_started` test asserts exactly 2,000 bytes, so it fails if the cut is gone, and it writes no fake-program scenario that it never reads. Skipped: the last assistant model kept in the state, because one walk per harness call costs no more than the transcript append.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | The exit wait has no test at its limit: the test asserted only under 8 s, which a wait of 0 ms passes. | The test asserts 5,000 to 7,999 ms. |
| Spec | The lost-session restart at the deadline runs in no test. | Test "a lost-session result whose program does not exit starts the fresh run at the deadline". |
| Spec | The `not_started` deadline is not tested. | Not changed: the watchdog exits at once when the program does not start, and no fake makes it stay; the path sets its deadline in the same function as the tested one. |
| Spec | The comment on `next/1` says the exit wait runs from the result. | "from the terminal". |
| Standards | `await_exit/2` does not wait. | Renamed `arm_exit_wait/2`. |
| Standards | The failure column of the row "Claude Code exit wait" names only the result's terminal. | "ends with its terminal". |
| Standards | The path size in the `not_started` test is not explained. | A comment. |
| Failure path | None reproduced. A flood of output after the result (`exec yes junk`, `cat /dev/zero`) still ends at the deadline. | None. |

Fix diff: 14 lines in 1 code file, a renamed function. Full round, because a rename is in doubt as a removed and added function.

### Round 7, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify applied: the lost-session test calls `run_direct/3`, which takes options and moves to module level. Skipped: an application env key for the exit wait, so that the two exit-wait tests run in about 200 ms and not 5 s each, because it adds configuration for a value that never changes in use.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | The row "Claude Code error text" says `inspect/1` bounds the render further, but it escapes a printable byte to two: a text and a subtype of 2,000 escape bytes each render in 8,029 bytes (measured), and no test holds the render at the limit. | The row states the render bound, twice the two cuts, and test "a Claude Code error at its 2,000-byte cuts renders in at most 8,029 bytes" holds it. |
| Spec | When the child dies after the go-ahead and before the `exec` of `/bin/sh`, the watchdog's text is not JSON, so the turn ends with `{:claude_code_exit, 0}` and no text. | Not changed: only a failed `exec` of `/bin/sh` reaches this path; the text is lost, not unbounded, and the turn still ends. |
| Standards | `run_direct/3` sits between tests. | Moved to the helpers. |
| Standards | The two exit-wait tests repeat the timing check and the 5,000 ms literal. | Not changed: two uses. |
| Standards | The round-6 fix line names one code file, but the test file changed too. | Not changed: the count leaves out test files, as `/ship` says. |
| Failure path | None reproduced. A flood of output after a success or lost-session result ends at 5,037 to 5,116 ms. | None. |

Fix diff: 0 code lines (a test, a moved test helper, and a doc row). Reduced round.

### Round 8, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | `inspect/1` escapes U+00A0 to ` `, three times its bytes, so the error text renders in 12,029 bytes, not the 8,029 the row stated. | The second finding on the render bound of an error (with the next row), so the mechanism is fixed: the TUI cuts the render of every error at 8,192 bytes (`error_text/1` in `Helyx.TUI.ViewModel`), for every provider. Row "Error notice in the TUI". |
| Failure path, spec | `{:bad_stream_event, event}` carries the model's text with no cut: a `tool_use` with a non-string `id` and 200 keys of 5,000 escape bytes rendered in 1,525,821 bytes (reproduced); a nested `tool_use_id` object rendered in 771,337 bytes. This also makes the reason of the round-4 acceptance false. | The same cut. Test "an error renders in at most 8,192 bytes, with no character cut in half": U+00A0 text, a nested map, and a cut inside a 2-byte character. The event itself stays in memory within the 16 MiB line cap, as accepted in round 4. |

Fix diff: 10 lines in 1 code file, a new function. Full round, because of the new function and the two-findings rule.

### Round 9, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify applied: `error_text/1` uses `binary_slice/3`. Skipped: one shared byte-cut helper for `error_text/1`, `cap_error/1`, and the OpenAI cut, because the body is one line in two projects; `inspect/1` with a `printable_limit`, because it changes the text and bounds no total.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec, failure path | The line of a harness tool call has no render bound: `compact_arguments/1` shows the keys raw and each value through `inspect/1`, so a call of 500,000 keys and one key of 4,000,000 bytes rendered in 111,118 rows in 4,801 ms (reproduced), and values of U+00A0 render at three times the 16 MiB line cap. | The third finding on the render bound, so one rule holds both render sites: `ViewModel.cut_line/1` cuts the error notice and the tool call line at 8,192 bytes. Test "a tool call line is cut at 8,192 bytes". The model tool call had the same hole before this ticket and gets the same cut. |
| Spec | No test holds a `cut` of 100 digits, the digit limit, and none a cut of -1. | Tests "a cut of 100 digits is kept" and the fail list with `neg_cut`. |
| Standards | The round-9 skip says the cut is one line "in two projects", but the three sites are in `plugins/bundled`. | Corrected here: the three sites are in one project; the provider cuts at 2,000 bytes before the error term and the TUI cuts the render, so two limits stay. |
| Standards | `cap_error/1` and `error_text/1` share the attribute name `@error_max_bytes` with other values. | The TUI attribute is `@line_max_bytes` now. |
| Standards | The TUI attribute sits in the `defp` block. | Kept next to `cut_line/1`, its only reader. |

Fix diff: 17 lines in 2 code files, a new public function. Full round.

### Round 10, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify applied: the tool call line moves from `compact_arguments/1` in `Helyx.TUI` to `ViewModel.call_line/1`, so the pure module owns the whole line and its cut (altitude), and `cut_line/1` is private again. The join of the arguments stops once the line is over 8,192 bytes, so a call of many keys no longer inspects every value on each frame (efficiency). Skipped: `binary_slice/3` in `cap_error/1`, because its guard clause keeps a short text uncopied and is not in the fix; the measurements in the row, which state why `inspect/1` alone is not the bound.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | `call_line/1` turned newlines into "␤" over the whole line before the cut: a key of 8,000,000 newlines cost 1,545 ms per render, and a name of 15,000,000 newlines 5,829 ms (reproduced). | The line is cut before the replace and again after it, as "␤" is 3 bytes for 1. |
| Spec | The harness tool result cut has no test at its limit. | Test "a harness tool result is cut like a tool result", 3,000 lines through the session. |
| Spec | The text and thinking of a harness message have no stated screen bound: a 4,000,000-byte text wraps to 50,001 rows in 2,120 ms. | Stated and accepted in the row "Claude Code tool calls and messages per harness turn": the TUI does not cut a harness text, as it does not cut a model turn's text (row "Transcript scrollback"). |
| Spec | `Watchdog.close/1` became public with no reason in the diff. | Not changed: the provider closes the watchdog port with it in `stop/1` and at the exit wait; round 1 of this commit gave it `@doc false`. |
| Standards | `call_line/1` is called from `Helyx.TUI` but has `@doc false`. | A `@doc`. |
| Standards | `@line_max_bytes` names two limits of different sizes in one project. | The TUI attribute is `@render_max_bytes`. |

Fix diff: 10 lines in 1 code file. Full round, because the render-cost finding is the second on `call_line/1`.

### Round 11, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify applied: `@render_max_bytes` moves to the top of the module. Skipped: `inspect/1` with explicit limits for each value, because the default limits already bound one value (4,096 characters of a string, 50 elements, a budget over nested terms: a tree of 50⁴ integers renders in 401 bytes); one cut before the replace only, because a name or key can hold newlines; a fast path for a short line in `cut_line/1`.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | `Enum.reduce_while/3` over the arguments map turns the whole map into a list first: a call of 1,500,000 keys cost 55 to 188 ms per frame (reproduced). | The third finding on the cost of `call_line/1`, so the mechanism changes: `join_arguments/2` walks the map with `:maps.next/1`, which is lazy, and stops at the cut; the name and each key are cut before they join the line. Measured: under 1 ms per call after the first, for 1,500,000 keys, and for a name and a key of 16,000,000 bytes each. |
| Spec | The name and each key are copied whole into the line before the cut (1.7 ms for a key of 16 MB), against the `@doc` "the cost of a frame does not grow with the call". | The same change. |
| Spec | No test holds the cut after the "␤" replace. | Test "a tool call line of newlines is cut after they become ␤": a name and a key of 1,000,000 newlines. |
| Standards | The `@doc` and the comment write 8,192 next to `@render_max_bytes`. | The `@doc` interpolates the attribute; the comment names it. |
| Standards | The comments say "a notice", but `notice/2` does not cut. | "an error notice". |
| Standards | The `@doc` does not say that the key is shown raw. | It does. |

Fix diff: 33 lines in 1 code file, a new function. Full round.

### Round 12, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify: no change. Skipped: `inspect/1` with `printable_limit: @render_max_bytes` for each value, because the default `printable_limit` of 4,096 characters already bounds one value (a value of 15,000,000 newlines costs 2 ms, round 11).

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path, spec | A map inside one argument value goes whole into `inspect/1`, which lists and sorts every key before its `limit: 50`: a value map of 800,000 to 1,500,000 keys cost 13 to 101 ms per `call_line/1`, on each frame (reproduced). | The fourth finding on the cost of the call line, so the mechanism changes again: the fold makes the line once, when the call starts, and the tool cell keeps it, `{:tool, call, line, result}`; a frame renders the stored line and pays nothing for the call. The cost of `inspect/1` is paid once per call, as the error notice pays it once per turn. |
| Standards | The test "a tool call line of newlines is cut after they become ␤" calls only `ViewModel.call_line/1` but is in `tui_test.exs`. | Moved to `view_model_test.exs`. |

Fix diff: 24 lines in 2 code files; the shape of the tool cell changes. Full round.

### Round 13, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify: no change. Skipped: `Enum.map_join/3` over every argument in place of `join_arguments/2`, because the fold would then build and scan a line of up to 16 MiB for each call where the lazy walk stops at 8,192 bytes; the removal of the cut before the replace, because a name or key of newlines would then be scanned whole. The note that one value of 16 MiB goes whole through `inspect/1` is not true: its default `printable_limit` is 4,096 characters.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | Two harness calls with one id: the session gave a result to the oldest open call and the TUI to the newest, so each result showed under the other call, a `bash` call with the `read` output (reproduced). | The session gives a harness result to the newest open call with its id, as the TUI does. Test "a result goes to the newest open call with its id, as the TUI shows it". |
| Spec | The row says a map of 800,000 keys costs "up to 248 ms, once"; measured 13 ms to 1.7 s. | The row states the rule, not a number: the fold pays for `inspect/1` once per call, linear in the call and bounded by the line cap. |
| Standards | Each test site writes `ViewModel.call_line(call)` in the cell. | Not changed: the line is part of the cell, and each site states it. |
| Standards | The byte test of the call line in `tui_test.exs` now checks the stored line. | Not changed: it holds the render of the cut line through the wrap. |
| Standards | The tool cell is a positional 4-tuple. | Not changed, as the reviewer recommends. |
| Spec | Each harness result is a linear search of `turn.calls`. | Not changed: the count of calls in a harness turn is accepted as unbounded. |

Fix diff: 7 lines in 1 code file. Reduced round.

### Round 14, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec, failure path | The round-13 rule (a live result to the newest open call) disagrees with `open_calls/1`, which gives a result to the first: after one result for two calls with one id, the session records `bash` twice and `read` never, and the TUI shows the "aborted" result under `read` (reproduced on turn end, `fail_turn/2`, abort, and steer). | The second finding on the pairing of results, so the mechanism is chosen once: the session keeps one rule, the first open call, for the live result, the aborted results, resume, and the replay; the round-13 change is reverted. The TUI keeps its newest-open rule from #83. Accepted and stated in the row "Claude Code tool calls and messages per harness turn": a tool call id is unique from the API, and only a turn with two open calls of one id can show two results swapped on the screen. Test "a result goes to the first open call with its id". |

Fix diff: 7 lines in 1 code file (the revert of round 13). Reduced round.

### Round 15, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path | A harness turn that ends with an open call and no text after its last message appends an empty assistant message before the "aborted" result, so a message splits the call from its result (reproduced with read(t), bash(t), message_end, one result, done). | `end_turn/2` gives a harness turn's open calls their aborted results before it closes the last message. Test "a call with no result at done gets its aborted result before the last message". |
| Spec | `tool_id/1` in the replay is not one to one: `a.1` and `a_1` both become `a_1`. | Accepted and stated in the Replay section of the feature doc: provider ids are generated and unique in practice. No ticket for checkpoint one. |

Fix diff: 9 lines in 1 code file, no function added or removed, no shape changed. The finding is the first on the position of the aborted result at turn end (round 14 was the choice of the call). Reduced round.

### Round 16, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec, failure path | A harness `message_end` while calls of an earlier message are open appends the new message before their results: `[a, message_end, text "x", message_end, result a]` gives `asst(a), asst "x", result a` (reproduced by both agents; also on `fail_turn/2` after a text message). The Claude Code provider sends `message_end` only before a `user` line, so a real run needs text between two result lines. | The second finding on the place of an aborted result, so the mechanism is fixed: before the session appends any harness message (at `message_end` and at `done`), it gives the calls still open their `aborted` results. A later result for them finds no open call and is dropped. Test "a new message gives the open calls their aborted results, and a late result is dropped". |
| Spec | Row "Claude Code tool calls and messages per harness turn" said the replay always agrees; the Replay section now says `tool_id/1` can join two ids. | The row names the exception and the rule above. |

Fix diff: 6 lines in 1 code file. The two-findings rule applies, so the rerun is a full round.

### Round 17, full: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify: the altitude angle moved the rule of round 16 into `close_assistant/3`, the one function that appends an assistant message. It gives the calls in `turn.calls` their `aborted` results and clears the list before it appends. This replaces the guards of rounds 15 and 16 in `end_turn/2` and the `message_end` handler. In a model turn the list is always empty there. The efficiency and reuse angles proposed the same place. A single `events("open_call")` clause was skipped: it would not test a turn that ends with no text after its last message.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Standards | `close_assistant/3` built the state from the `turn` from before the reduce; this is safe only because `record_result/3` does not change the turn. | The list is cleared with `put_in/2` before the reduce. |
| Standards | The reduce with `{:error, "aborted"}` repeats the body of `abort_open_calls/1` with another list. | Skipped: a judgement call on two lines; a helper would add a function for no change of behaviour. |
| Standards | The round-15 row names code in `end_turn/2` that round 17 removed. | This round names the replacement. |
| Spec | The Stream section of the feature doc and the comment on the harness result handler did not state the new rule. | Both state it now. |
| Failure path | None reproduced. Observation, not new: a harness `message_end` or `done` with no partial appends an assistant message with empty content. | No change; a model turn does the same. |

Fix diff: 4 lines in 1 code file, no function added or removed. Reduced round.

### Round 18, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | The "open_call" test checked only the order of roles, not which call got the `aborted` result. | The test also checks `{"read", "one"}, {"bash", "aborted"}`. |
| Spec | The Stream section did not name the abort and the steer among the times a call gets its `aborted` result, and did not state the order of events when the next message already streams. | Both are stated. |
| Failure path | None reproduced (fail_turn, stream end, a result during the next partial, reused ids, steer). | No change. |

Fix diff: 0 code lines outside tests and Markdown. Reduced round.

### Round 19, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | The order sentence of the Stream section named only aborted results; a live result that arrives while the next message streams has the same event order. | The sentence names both. |
| Spec | No test covers a harness turn with an open call on an abort or a steer. | Skipped: the abort and the steer use `abort_open_calls/1`, the same code for both kinds, which "abort during tool calls ends the turn and answers every open call" covers; the failure-path agent probed the harness cells with no break. |
| Failure path | None reproduced (eight probes: reused ids during a partial, two open messages, raise, bad event, stream end, steer, abort, follow-up). | No change. |

Precommit then failed on Dialyzer: `Helyx.Test.BadKind.kind/0` returns `:bogus` on purpose. Fix: `@dialyzer {:nowarn_function, kind: 0}`, the pattern of the other test providers. Fix diff: 0 code lines outside tests and Markdown. Reduced round.

### Round 20, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Spec | The order sentence read as "after all the deltas"; a live result comes after the deltas sent before it only. | The sentence says "the deltas sent before it". Markdown only, so no rerun. |
| Failure path | None reproduced (reused ids with a switch of model, a follow-up, a steer, an abort, a bad event with a partial call). | No change. |

The round is clean for code.

Precommit then failed on Dialyzer in `plugins/bundled`: `improper_list_constr` at the two places in `lines/2` of `claude_code.ex` that build the line buffer as `[state.buffer | part]`. Fix: `[state.buffer, part]`, a proper list of the same bytes. Fix diff: 4 lines in 1 code file, no function added. Reduced round.

### Round 21, reduced: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Spec: no finding. The old form was valid iodata with the same bytes; the fix is for Dialyzer, not for byte order. Failure path: no finding (a line at the cap in one-byte chunks with split `é` characters, one over, one under, empty and mixed chunks). The round is clean.

Precommit: passed.

## Codex round 1 (after the rebase on origin/master)

| Severity | Finding | Resolution |
| -------- | ------- | ---------- |
| High | After a lost-session retry, the `init` of the fresh session stores its id at once. An abort, a failure, or a restart can come before the fresh session makes a message. Then the last assistant message is still from the same provider (the old session), so `resumable/2` returns the new id. The next turn resumes a session that never got the full replay and sends only the prompt. | Invariant: a harness session id is resumed only when that harness session has the transcript up to its end. Each harness session is kept with the number of transcript messages before its entry, in memory and, from the entry's place in the file, on resume. `resumable/2` returns the id only when the last assistant message came from the provider after that harness session's entry. Test "a fresh session aborted before its first message is not resumed, in memory or after a restart" (it failed before the fix: the next turn passed `--resume`). |

Fix diff: 2 code files, and the shape of `harness_sessions` changes. Full round.

### Codex fix, full round: simplify, standards, spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Simplify: `resumable/2` drops the messages before the entry with `Enum.drop/2` and keeps the old `last_assistant/1`, so no index is threaded. Skipped: the altitude angle proposed to hold the id at `init` and write the entry at the first message; the user's decision for #10 is that the entry is written at `init`.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Standards | `start`, `stored`, and `id` in `resumable/2` did not say what they hold. | Renamed to `before`, `harness_id`, and `provider`. |
| Standards | The count in memory and the count from the file must agree; a named type for the pair. | Skipped: every message goes through `append_message/2`, which writes the file in the same order, and the restart test checks it. A type for one use adds a name for no change. |
| Standards | One Resume sentence and one review cell were not STE; the review used another term than the feature doc. | Rewritten. |
| Spec | None. Steer and `fail_turn` have no test of their own; they use the same mechanism. | No change. |
| Failure path | None reproduced (a fresh session that fails after one delta, a steer before its first message, a switch and back, a late `init` from an old Task). | No change. |

Fix diff: 6 lines in 1 code file (renames), no function added. Reduced round.

### Codex fix, reduced round: spec, failure path

Bounds sensor: skipped: TYPESAFE_API_KEY is not set.

Spec: no finding (the renames keep the logic). Failure path: no finding reproduced (the boundary at the entry, the count after a restart, disk write failures, a lost resume and a fresh start in one turn). The round is clean.

Precommit: passed.

## Codex review

- Round 1 (after the rebase): 1 finding, confirmed. A fresh session from a lost-session recovery that was interrupted before the replay completed was resumed on the next turn, so the history was lost with no notice. Fixed in `61b1750`: a harness session is resumed only after it has made a message.
- Round 2: 1 finding, rejected by the orchestrator. The claim was that an `aborted` result that Helyx adds for an open call after an abort or a failure never reaches the harness, so the next resumed turn uses a different tool history. A real run (research note, "A run killed during a tool call can be resumed") shows that Claude Code closes the open call of a killed run by itself, and that the model knows the result is unknown. That is the meaning of the `aborted` result, so the histories agree. The proposed fix, a full replay after every abort during a tool call, would replace the harness's own context with the text replay on each Esc.
