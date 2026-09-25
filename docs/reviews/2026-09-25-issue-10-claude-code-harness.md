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
