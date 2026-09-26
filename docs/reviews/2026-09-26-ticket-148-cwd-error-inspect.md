# Review: command-line arguments in `mix helyx` errors (#148)

Base: `origin/master` at `37ff492`. Round 1 is the first and complete round. Rounds 2, 3, and 4 are full rerun rounds.

## Change

`Mix.Tasks.Helyx.run/1` shows every command-line argument in an error through `inspect/1`. This is the owner decision on the ticket. The new private `parse/1` rejects an argument that is not valid UTF-8 before `OptionParser` gets it. Then it calls `OptionParser.parse/2`, not `parse!/2`, and shows each bad switch and its value through `inspect/1`.

Invariant: at the entry point `Mix.Tasks.Helyx.run/1`, the command line is the boundary. No error message holds a raw byte from it, and no bad argument ends in an exception other than `Mix.Error`.

Decisions:

- The ticket names only the "not a directory" error. The "at most one directory" error and the option error echo the same argv at the same boundary, so the change fixes them too.
- An argument that is not valid UTF-8 gets the error "an argument is not UTF-8", shown with `inspect(bad, binaries: :as_strings)`. `OptionParser` raises on some of these arguments, and `Helyx.Session` rejects such a directory with `:invalid_cwd`.
- The option error no longer lists the supported options in the `OptionParser` layout. It names the two options in one sentence.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

No doc states a bound for these messages. `inspect/1` stops a string at 4096 printable characters. The OS limit on argument size bounds the option error, which has one entry for each bad switch.

## Round 1

Findings: simplify 3, standards 1, spec 0 (1 out-of-scope note), failure path 2.

- Simplify, fixed: the test had two redundant cases and repeated assertions. It is now one table.
- Simplify, skipped: send the messages through a shared cleaning function, as `CodingAgent.error_text/1` does. The owner chose `inspect/1`.
- Standards and failure path, fixed: the `OptionParser.ParseError` rescue passed the raw switch name into the error (`["--x\e[31mY"]`).
- Failure path, fixed: a switch name that is not UTF-8 (`["--x\xFF"]`) raised `ArgumentError` from `OptionParser.format_error/3`, not `Mix.Error`.

Fix: `OptionParser.parse/2`, with the bad switch names through `inspect/1`. Full rerun: more than 15 lines.

## Round 2

Findings: simplify 1 (nit, skipped), standards 3, spec 2, failure path 0.

- Fixed: the option error dropped the value and called a valid switch with a missing value a "bad option". Each pair now shows as `inspect(name)` or `inspect(name)=inspect(value)`, under "unknown option or bad value".
- Fixed: `if invalid != []` is now a `case` with pattern matching.
- Fixed: the test now checks that the inspected form is in the message, and it covers `--model` with no value and `--resume` with a bad value.
- Skipped (altitude): keep `parse!/2` and clean its text. That brings back the `ArgumentError` crash.
- Follow-up, not changed: `mix helyx.graph` has the same `parse!/2` pattern.

Full rerun: the fix adds a function.

## Round 3

Findings: simplify 0, standards 2 (minor), spec 2, failure path 1.

- Fixed (spec and failure path): a short switch that is not UTF-8 (`["-a\xFF"]`) raised `UnicodeConversionError` from `OptionParser.parse/2`. This is the second finding on one mechanism, `OptionParser` with input that is not UTF-8. The fix is on the mechanism: every argument that is not valid UTF-8 stops before `OptionParser`.
- Fixed (spec): with the check above, every later `inspect/1` gets a valid string. Thus a bad byte no longer turns the message into a byte list that stops after 50 bytes.
- Fixed (standards): the `--resume` test row now checks the switch and the value.
- Not changed (standards): the three older plain assertions stay as readable cases.
- Accepted (failure path): an unknown switch shows without its value, because `OptionParser` gives `nil`. The old text did not show it either.

Full rerun: two findings on one mechanism.

## Round 4

Findings: simplify 1, standards 2 (minor), spec 0, failure path 0.

- Fixed (simplify): the UTF-8 check is an `if`, not a `with`.
- Fixed (Credo strict): `run/1` was too complex. The check and the parse are now in the private `parse/1`.
- Skipped (standards): write the `if` as a `case`. This conflicts with the simplify finding.
- Skipped (standards): add a comment to the two UTF-8 test rows.
- Skipped (spec, optional): state the UTF-8 rule in the moduledoc.
- Failure path: 35 inputs, among them switch names at the 255-character atom limit, bidi and zero-width characters, NUL, `--`, and a 5000-character path. All end in `Mix.Error` with the argument through `inspect/1`. Not tested: a current directory that is not UTF-8, because macOS APFS does not make one.

## Round 5 (Codex round 1)

Codex found that `OptionParser.parse/2` raises `ArgumentError` from `expand_multiletter_alias/2` on some valid UTF-8 switches, such as `-=` and `-=value`. This is the second finding on one mechanism: `OptionParser` raises on some inputs.

Fix on the mechanism: `parse/1` rescues `ArgumentError` by name around `OptionParser.parse/2` and raises `Mix.Error` with the whole argv through `inspect/1`. `OptionParser` does not tell which argument failed. A fuzz of 300000 random valid UTF-8 argv lists found no other exception type. A read of the `OptionParser` source in Elixir 1.19.5 found no other raise that argv can reach with `strict:`.

The UTF-8 check stays. The rescue does not prove the same property: a long switch or a positional argument that is not UTF-8 does not raise, and without the check `inspect/1` shows it as a byte list cut after 50 bytes. There is no `UnicodeConversionError` clause, because nothing can reach it after the check.

Regression cases: `-=`, `-=value`, and `-=` with control characters. Full rerun: more than 15 lines, and the two-findings rule applies.

Findings: simplify 1 (nit, skipped), standards 2 (minor), spec 0, failure path 0.

- Skipped (simplify and standards): remove the `parsed` variable with `case` over the `try`, or with a `try ... else`.
- Skipped (standards): rename `@options` to `@options_hint`.
- Not changed (spec and failure path): a NUL byte in a directory argument shows as a byte list. A real OS argv cannot hold NUL.
- Not changed (spec): `--=x` shows as `"--"` without `=x`. This does not break the invariant.
