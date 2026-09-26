# Review: the harness providers check for perl (#141)

Base: `origin/master` at `a17382b`. Seven rounds. Every round was full: simplify with four agents, then the standards, spec, and failure-path axes. From round 3, each fix changed a mechanism, so no rerun was reduced. The fixes after round 7 changed only comments and Markdown, so no rerun round followed.

## Change

`Helyx.HarnessIO.find/1` looks up the harness program and perl. `Helyx.Provider.ClaudeCode.stream/3` and `Helyx.Provider.Codex.stream/3` call it. Without perl, the turn fails with `perl not found on PATH: <program> runs under a perl watchdog`, and the session lives. The `|| "/usr/bin/perl"` fallback in `Helyx.Watchdog.launcher/5` is gone. perl can go away after the check, so `Helyx.Watchdog.start/4` handles the failure where perl is used. A failed lookup or spawn gives `{:no_marker, "perl did not start: ..."}`, and a watchdog that ends with no marker gives `{:no_marker, "the perl watchdog gave no marker: ..."}`. Neither raises. `HarnessIO.cap_error/1` now drops every invalid byte, not only a character cut in half. The bash tool keeps the head of a no-marker error, cut as in the harness providers, so the words that name perl stay. The TUI renders an error with `inspect(error, binaries: :as_strings)`, so a control or invalid byte shows as an escape, not as a list of bytes. `Helyx.Tool.Bash.check/0`, the watchdog protocol, and every deadline are unchanged (ADR 0004).

Invariant: when perl is missing or goes away, a harness turn or a bash call ends with an error whose visible text names perl, and nothing raises.

Size: about 111 lib lines added and removed, over the 100-line mark. This was reported before round 6. The review findings made the watchdog failure handling and the bash and TUI render paths part of the change.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

Findings: 2.

- Fixed: `launcher/5` looked up perl again with no check, and a `nil` executable raised in `Port.open`. `Bash.run/2` raised too. The failure-path agent reproduced it.
- Fixed: the feature doc did not name the check in the providers.

## Round 2

Findings: 2.

- Fixed: perl removed between the lookup and `Port.open` raised `:enoent`. The failure-path agent reproduced it with a flapping symlink. `open_port/2` now rescues `ErlangError` and returns a result.
- Fixed: a perl that started and exited with no output gave an empty error text.

## Round 3

Findings: 2. Two findings on one mechanism, the no-marker text, so the mechanism changed: the text now names the perl watchdog, not a cause.

- Fixed: a no-marker text that was not empty did not name perl.
- Fixed: the special case for an empty text blamed perl for E2BIG. The failure-path agent reproduced it with a 1.1 MB command.

## Round 4

Findings: 1.

- Fixed: the bash `:tail` cut dropped the perl prefix of a long preamble. Reproduced with `LC_MESSAGES` set to 5,000 newlines, or to 60,000 `x`. Bash now keeps the head of a no-marker error through `HarnessIO.cap_error/1`. A test covers both values, and its assertion message shows no environment value.

## Round 5

Findings: 3.

- Fixed: a short text with an invalid byte passed `cap_error/1` raw, and the TUI showed it as bytes. `cap_error/1` now drops every invalid byte.
- Fixed: a feature doc row went stale.
- Fixed: a test comment was not clear.

## Round 6

Findings: 1, found on all three axes.

- Fixed in round 7: a control byte (`\x01`, U+0085, U+FFFF) is valid UTF-8, but `inspect/1` in `Helyx.TUI.ViewModel.error_text/1` still showed the error as a list of bytes with no word perl. This was the second finding on the render, so the fix moved to the render: `inspect(error, binaries: :as_strings)`, with a test for a control byte, U+0085, and an invalid byte.

## Round 7

Findings: no defects. Comment and doc fixes:

- Simplify: a Codex test comment and the `cap_error/1` comment still said that the drop of invalid bytes makes the text render. They now say that it makes the text valid UTF-8, for the model too.
- Standards and failure path: the doc row and the `cut_line/1` comment said that `inspect/1` escapes to three times the bytes. With `:as_strings`, a control or invalid byte renders as `\x01`, four times. Fixed.
- Spec: row "bash watchdog marker read" now says that the 2,000-byte cut applies after the `the command did not start: ` prefix.
- Checked, no change: with `:as_strings`, `inspect/1` of a large error term can take about 3 MB before the 8,192-byte cut. The per-string and per-collection limits still bound it, once for each failed turn, as the doc row already accepts.

Skipped:

- Tool call arguments in the TUI still use `inspect/1`, so a control character in an argument shows as bytes. This is outside #141.
- `docs/adr/0004-os-resource-ownership.md` and `docs/features/tool-resource-release.md` name `Helyx.Watchdog.start/3`. Both arities exist, and the text is older than this change.

## Rejected or out of scope

- A perl that hangs: ADR 0004, and the doc row on the marker read already accepts it.
- No ARG_MAX bound on a bash command: older than this change.
- A NUL byte in a provider's model or cwd gives an `ArgumentError` from `Port.open`, or a silent cut. This is a separate boundary. Follow-up ticket suggested.
- The harness `{:not_started, port, acc}` head cut drops the watchdog's reason when perl's warnings come first. Older than this change. Follow-up ticket suggested.
- The text for an empty no-marker ends in a colon. Kept: the prefix is constant.
- The `:no_marker` tag also carries "perl did not start". Kept: both mean no marker, and both texts name perl.
- `Helyx.Tool.Bash` calls `HarnessIO.cap_error/1`. A helper call, allowed by ADR 0005.
- A shared `Watchdog.perl/0`: skipped, because `Bash.check/0` stays as it is.

## Orchestrator

- Codex adversarial review, round 1: 1 confirmed finding. `open_port/2` did `rescue error in ErlangError -> inspect(error.original)`. The rescue also catches a normalized exception, such as `SystemLimitError` at the BEAM port limit or `ArgumentError`, which has no `:original` field, so it raised `KeyError`. Codex reproduced it with `+Q 1024` through `Bash.run(%{"command" => "true"}, "/")`.
- Fixed: the text is now `Exception.message(error)`. A regression test in `watchdog_test.exs` passes a cwd that is not text, so `Port.open` raises `ArgumentError` deterministically, with no VM flag for the suite. The test also checks that the spawn ran, not the perl lookup.
- Rerun round 8, reduced (spec and failure path; the fix is one code line in one file and a test): 1 finding on spec, the test also matched a failed perl lookup, fixed. The failure path was clean. It reproduced the port limit in a separate VM with `+Q 1024`: `{:error, "the command did not start: perl did not start: a system limit has been reached"}`.
- Text change: a missing file was `perl did not start: :enoent` and is now `perl did not start: Erlang error: :enoent`. No test or doc depends on the old text.
