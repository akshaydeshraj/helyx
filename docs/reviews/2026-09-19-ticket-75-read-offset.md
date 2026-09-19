# Review: ticket #75, the read tool ignores an offset that is not an integer

Date: 2026-09-19. Branch `ticket/75-read-offset`, base `origin/master` at `667e0a0`.

Invariant: an `offset` argument of the read tool is never replaced by the default in silence. The read starts at the line that the model asked for, or the result is an error that names `offset`, the expected type, and the kind of the value. The error never shows the value, so its size (111 bytes at most) and its cost in the tool do not depend on the argument.

Documented exceptions:

- A missing or `null` offset is line 1.
- A float with no fraction, such as `2001.0`, is its integer.
- The tool has no `limit` argument. It ignores a `limit` key like any key that the schema does not name. A real `limit` needs a change in `Helyx.Tool.truncate/3`, which was outside the scope of the worker. Ticket pending.
- An offset after the last line gives an empty ok result with no notice. This is older than #75. Ticket pending.

## Simplify

Four agents: reuse, simplification, efficiency, altitude. Reuse, efficiency, and altitude reported clean.

- Simplification, applied: the float test and the null test became one table test.
- Simplification, not applied: one `with` for the offset and the file read. The read error gets new text, so that form needs an `else` that must tell the two errors apart.

## Round 1, complete round

Bounds sensor, base `origin/master`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Standards: 0 hard violations, 4 judgement calls.
  - Applied: the moduledoc sentence became three short sentences. The comment above `offset/1` lost the text that repeated the moduledoc.
  - Not applied: rename `offset/1` to `parse_offset/1`. The name with the `{:ok, offset}` match is the usual Elixir form.
  - Not applied: the schema says `integer` and the code accepts `2001.0`. The ticket requires this.
- Spec: 4 findings, all test or doc gaps.
  - No test for the `limit` key. Fixed: a test pins that the key is ignored.
  - No test for a large float. Fixed: `1.0e300`.
  - No test for the order "error before the file read". Fixed: a bad offset with a missing file.
  - The doc said `ignores a limit key` with no pointer to later work. Fixed: `ticket pending`.
  - Not applied: "JSON encoders" against "JSON decoders" in the ticket. The model side encodes the arguments, so "encoders" is correct.
- Failure path: 0 reproduced defects. 2 observations.
  - The error text for a wide map was 583 bytes, and the doc said only "small". Fixed at that time with a stated bound of 1,000 bytes and a map case in the test. Round 2 broke that bound.
  - An offset after the last line gives `{:ok, ""}`. Older. See the exceptions.

## Round 2, reduced round

The fix changed 8 code lines in one code file (`plugins/bundled/lib/helyx/tool/read.ex`, moduledoc and comment text only). It added no function and changed no arity, return shape, or spec. Thus the round was reduced: spec and failure path, both briefed with the invariant.

Bounds sensor, base `HEAD` with the round 1 change in the working tree:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Spec: 1 finding. The doc claim "under 1,000 bytes for any argument" was false. `inspect/2` does not limit an integer: a negative integer of 100,000 digits gave a text of 100,064 bytes. A list of 9 strings of 4-byte characters gave 1,123 bytes.
- Failure path: 1 finding, the same mechanism. `printable_limit` counts characters for each string, not bytes of the text. Five map pairs of zero-width spaces gave 3,184 bytes.

This was the second finding on one mechanism, the echo of the value through `inspect/2`. By the two-findings rule, the fix replaced the mechanism. The error now names the kind of the value (`kind/1`) and never shows the value. The text is a constant for each kind, and the longest is 111 bytes.

## Round 3, complete round

The fix added a function, so the round was complete.

Simplify: reuse and efficiency reported clean.

- Simplification, not applied: remove the `-1` and `-2.0` rows and the loop in the `limit` test. The ticket names zero and a negative number for both arguments.
- Altitude, not applied: delete `kind/1` and give one constant text. `got a string` tells a model that sent `"2001"` what to change.

Bounds sensor, base `HEAD`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Standards: 0 hard violations.
  - Applied: the comment about the float moved to the float clause. The `ticket pending` text in the doc became full sentences.
  - Not applied: the `parse_offset/1` rename, as in round 1.
- Spec: 0 wrong behaviour. 3 gaps.
  - No test asserted the 111-byte bound. Fixed: `byte_size <= 111` for every kind.
  - No test for a `path` that is not a string. Fixed.
  - No research citation in the row. Fixed: pi and opencode both have `offset` and `limit`.
  - Not applied: tests for a wrong type in `bash`, `edit`, and `write`. Those files were outside the scope of the worker. The claim is true in the code: each `run/2` guards every argument with `is_binary/1` and has a catch-all clause that returns an error.
- Failure path: 0 reproduced defects.

## Round 4, reduced round

The fix moved one comment, 2 code lines in one code file. Thus the round was reduced.

Bounds sensor, base `HEAD`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Spec: 0 findings. One optional test row, `-0.0`. Added.
- Failure path: 0 findings in the diff. 1 older defect outside the ticket.
  - The session encodes the arguments of every tool call to JSON for the session file (`lib/helyx/session_file.ex`, `JSON.encode!`). The cost is quadratic in the digits of a large integer: 161 ms for 100,000 digits, 2,483 ms for 400,000 digits. `Helyx.Tool.Read.run/2` takes 3 microseconds for the same value. Any tool with any integer argument has this cost. Not applied. The orchestrator filed #78 for the empty result and #79 for the slow integer, and accepted the missing `limit`.

The changes after round 4 were one test row and Markdown, so no more rounds were necessary.
