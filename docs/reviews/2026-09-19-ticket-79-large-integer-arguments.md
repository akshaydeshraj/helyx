# Review: ticket #79, a very large integer in tool call arguments makes the turn slow

Date: 2026-09-19. Branch `ticket/79-large-integer-arguments`, base `origin/master` at `b6f22e7`. `origin/master` moved to `712de5d` during the work.

Invariant: no value that the session accepts from a provider holds an integer of more than 100 digits, at any depth of maps with their keys, lists, tuples, and structs. The values are the arguments of a tool call, the usage, and every terminal of the provider Task: `:done`, an error reason from the stream or from `stream/3`, and the `{:bad_stream_event, _}` reason. `Helyx.Message.cap_integers/1` replaces each such integer with the string `integer of more than 100 digits removed` before the first JSON encode. The reason of a Task exit gets the function when the session puts it in the events. Arguments and a usage are plain maps: a struct in their place is a malformed stream event. Thus no later step sees the large integer: the events, the transcript, the session file append, the tool, a client that calls `inspect/1`, and each later provider request. A tool call whose arguments changed gets an error tool result in bounded time and its tool does not run. The other calls of the message run.

Entry points: three. The provider Task in `start_provider_call/1` and `consume/3` of `lib/helyx/session.ex` is the only path for stream events and terminals. `consume/3` builds the tool call and the `:done` terminal again from their known fields, so the shape that the session needs holds after the cap. The `:DOWN` handler of the session caps the reason of a Task exit. `decode_block/1` and `decode_usage/1` in `lib/helyx/session_file.ex` are the only path from a session file to the transcript on `Session.resume`; a file from before #79, or a file that a person changed, can hold a large integer. A restored call never runs: it has its result in the file, or it gets the `aborted` result.

Documented exceptions:

- An integer of more than about 1,262,611 digits (4,194,304 bits) is over the integer size limit of the BEAM. `JSON.decode/1` in the provider raises `SystemLimitError`. The provider Task exits and the turn fails in 5 ms with no tool result. The session accepts the next prompt. A clean error is a change in the provider, ticket pending.
- The time of the JSON decode in the provider is before the check. It is bounded by the limit above: 197 ms at most.
- A second call of the same assistant message that is equal to a rejected call after the replacement (same id, same name, same capped arguments) is also not run. A call with the same id and other arguments runs.
- A struct that holds such an integer becomes the marker string as a whole.
- A provider that raises or exits with such an integer in the reason: the crash report of the Task makes the digit text before the session gets the `:DOWN` message (3,062 ms for 400,000 digits in round 3). The session caps the reason that it puts in the events, but the turn is slow and the log holds the digits. Providers are compiled into the node. Ticket pending.
- A session file that a person changed can hold a large integer in a field that is not arguments or usage. `SessionFile.resume/2` then makes digit text in its error: 3,035 ms for 400,000 digits as the entry `type` (`inspect/1`), 18.8 s for 1,000,000 digits as the `content` (`Exception.message/1`). This is older than #79 and is not a value from a provider. Ticket pending.
- A float is not changed. Its encode is short at any size of the source text.
- The `usage` map of a `:done` event gets the same replacement in `consume/3` (round 1). No tool result exists for it, so the turn goes on with the marker string where a token count was. The usage stays a plain map, and no code in `lib`, `plugins/bundled/lib`, or `apps` does arithmetic on it.

## Trace

OTP 28, Elixir 1.19.5, `:timer.tc`, arguments `{"offset": N}` with N of d digits.

| digits | `JSON.decode/1` | `JSON.encode!/1` | `Message.valid_utf8?/1` |
|---|---|---|---|
| 1,000 | 2.4 ms (first call) | 0.5 ms | 0.6 ms |
| 10,000 | 0.1 ms | 1.9 ms | 0.0 ms |
| 100,000 | 3.4 ms | 185.0 ms | 0.0 ms |
| 400,000 | 29.9 ms | 2,990.8 ms | 0.0 ms |
| 1,000,000 | 120.0 ms | 18,654.4 ms | 0.1 ms |
| 1,262,000 | 197.1 ms | not measured | not measured |
| 1,300,000 | raises `SystemLimitError` | | |

- The slow step is the JSON encode, as the ticket guessed. The decode is not quadratic and has a ceiling of about 200 ms.
- The ticket named one encode site. There are three. `Message.encodable?/1` in `consume/3` encodes the arguments in the provider Task. `SessionFile.append_message/2` encodes them in the session process, which blocks the session. `Helyx.Provider.OpenAI` encodes them in each later request of the session.
- Through `Helyx.Provider.OpenAI.events/1`: 30.1 ms for 400,000 digits, 199.8 ms for 1,262,000, and a raise after 5.3 ms for 1,300,000.
- A compare of the integer with `10 ** 100` takes 0.0 ms at 1,262,000 digits. A copy of the arguments to another process takes 0.1 ms.
- Worst arguments at the limit, 10 MiB of integers: 103,819 integers of 100 digits encode in 47.6 ms (60 ms in a run of the spec reviewer, so the docs say about 50 ms). For a limit of 1,000 digits the number is 142.2 ms. The worst cost grows with the limit, so the limit is small: 100 digits, 5 times the 20 digits of a 64-bit value.
- After the fix, the session test with an integer of 400,000 digits, three calls, and a session file takes 35 ms. Before the fix it did not end within 1 s.

Choice: the check is on the decoded arguments in the session, not on the raw argument text in the provider. The decode is not the slow step, and a check in the session covers every provider.

## Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Reuse: clean.
- Author, after the simplify pass: the resume path was a second entry point with no check. `decode_block/1` now applies `cap_integers/1`, with a test.
- Simplification, efficiency, and altitude, applied: the first version walked the arguments in the provider Task and again in the session process (60 to 90 ms in the session for 10 MiB of small values). Now the Task walks one time and tells the session which call it rejected (by id in this pass; round 1 changed it to the capped call).
- Simplification and altitude, applied: `rejected` holds call ids, not calls. Round 1 reverted this.
- Simplification, not applied: reset `rejected` where `end_turn` sets `calls`. The ids arrive before `end_turn`, so that reset loses them.
- Simplification, not applied: remove `Message.max_integer_digits/0`. The error text is the text of the session, and the limit has one source.
- Altitude, not applied in this pass: a digit limit for the `usage` map. Round 1 applied it.

## Round 1, complete round

Bounds sensor, base `origin/master`:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

- Standards: 1 documents violation, 6 judgement calls.
  - `ticket pending` has no ticket number. Not applied: the worker for this ticket must not create GitHub issues. The orchestrator files the ticket and puts the number in.
  - Not applied: rename `cap_integers/1`; return a tagged tuple from it. The `!=` compare runs in the provider Task and costs about 12 ms for 10 MiB.
  - Not applied: a flag in the `:stream_event` message in place of `:rejected_call`. The session must store the flag for each call until `run_tool/2`, so the field stays.
  - Not applied: the `if` in `run_tool/2`, the literals in tests, and `max_integer_digits/0`. The reviewer called each acceptable.
- Spec: 1 defect, 4 gaps in docs and tests.
  - `cap_integers/1` did not change map keys. See the failure path.
  - No test one under the limit. Fixed: 99 digits in `test/helyx/message_test.exs`.
  - `48 ms` was too exact. Fixed: `about 50 ms`.
  - The cap on resume is outside the text of the ticket. Kept: without it a file from before the fix gives the large integer to every later provider request. The file bytes do not change.
  - Not applied: the sentence `Its only bound is the 10 MiB limit on tool call bytes` in the read offset row. It is about PATH, a string.
- Failure path: 3 reproduced findings.
  - Two calls with one id: the good second call did not run, because `rejected` held ids. Fixed: `rejected` holds the capped calls and `run_tool/2` compares by value. The session test has a good call with the id of the rejected call.
  - An integer of 400,000 digits as a map key: the turn took 3,004 ms. Only a provider that builds its own maps can send it. Fixed: `cap_integers/1` replaces keys too.
  - An integer of 400,000 digits in `usage`: the turn took 2,988 ms. `Helyx.Provider.OpenAI` accepts each integer from the wire. Fixed: `consume/3` caps the usage with the same function. The session test covers it.
  - Probed with no defect: a list with 2,000,000 levels (42 ms, no raise), 100,000 integers of 100 digits (walk 1 ms), the order of `:rejected_call` and its stream event, a stale `:rejected_call`.

The fix touches two code files and changes the shape of the `:rejected_call` message. Round 2 is a full round.

## Simplify, second pass

One agent with the four angles. This is a deviation from the four agents of `/simplify`.

- Reuse: clean.
- Efficiency, not applied: `consume/3` walks the arguments three times (cap, compare, encode). Each walk is linear and the encode is the slowest. A walk that also returns a flag adds code and saves little.
- Simplification, applied: a comment says why each provider call starts with an empty `rejected` list.
- Altitude, applied: the same comment states the compare by value and its limit.
- Altitude, not applied: a cap in `decode_usage/1` on resume. No step encodes a restored usage again.

## Round 2, full round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Standards: 3 documents findings, 4 judgement calls.
  - The devlog still said that the Task sends the id. Fixed.
  - The `@doc` of `cap_integers/1` named one caller of three. Fixed.
  - The marker string in `usage` was not a documented exception. Fixed above.
  - Applied: a comment on `@integer_limit`; `huge` is bound one time in the test provider.
- Spec: 1 defect, 5 doc statements.
  - A struct passed the walk. See the failure path.
  - `{huge}` in the arguments failed the turn in 3 ms, but the error reason held the integer and `inspect/1` of it took 3,098 ms. The TUI calls `inspect/1` on the error. Fixed: the walk covers tuples, and the error reason holds the capped event.
  - Stale or too strong statements in the `@doc`, a test comment, the devlog, this record, and the `one place` comment in `consume/3`. Fixed.
- Failure path: 1 reproduced finding. The round 1 reproduction with two calls of one id passes.
  - `%Date{year: huge}` and `%Duration{second: huge}` in the arguments, and the `Date` in `usage`: the turn took about 5,960 ms, the tool ran, and the session file got 401,056 bytes. JSON encodes these structs, and the walk skipped structs.
  - This is the second finding on the walk (round 1: map keys). The fix is on the mechanism, not on the path: the walk now covers every compound term of the BEAM, which are maps with keys, lists, tuples, and structs. A struct that holds such an integer becomes the marker as a whole. The session test has a `Date` call.
  - Not applied: reject every struct, tuple, and atom key at the stream check. `Helyx.Provider.OpenAI` sends `usage` with atom keys, and the older `encodable?/1` contract accepts a `Date`. That is a change of what a provider can send.

The fix adds two function clauses. Round 3 is a full round.

## Simplify, third pass

One agent with the four angles, as in the second pass.

- Altitude, applied: the catch-all clause of `consume/3` put a malformed event into the error reason with no cap, so the tuple clause did not cover that path. Now the reason holds the capped event. A test sends a malformed event with an integer of 400,000 digits.
- Simplification, not applied: remove the struct clause. Round 2 reproduced the `Date` case.
- Efficiency, not applied: the struct clause makes a capped copy of the fields only to compare it. The cost is negligible.
- Reuse, not applied: make the comments at the two call sites shorter. Each says what is specific to its site.

## Round 3, full round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Standards: 6 stale statements in docs, 3 judgement calls. No code violation.
  - The `@doc`, the invariant, the row name in two places, the `one check` sentence, the devlog, and the word `rejected stream event`. All fixed.
  - Applied: `huge/0` in the test provider, and the comments there.
- Spec: 2 paths, 3 doc statements.
  - An extra key in the `:done` map went into the `{:bad_stream_event, _}` reason: `agent_end` of 166,364 bytes.
  - An extra key in the tool call struct: the call ran and each event was about 166 KB.
- Failure path: 3 findings. The four given reproductions hold at about 33 ms each. `cap_integers/1` did not raise on a struct with no module, a map with `__struct__: "str"`, a tuple of 1,000,000 elements, or a list of 1,000,000 levels.
  - The `:done` extra key, as above.
  - An error reason from a provider had no cap: a stream event `{:error, {:oops, huge}}`, `stream/3` that returns `{:error, huge}`, and `exit({:bye, huge})`. Events of about 166 KB.
  - `decode_usage/1` had no cap on resume, and an encode of the restored usage took 3,209 ms. The reviewer also reported 62 s for its whole test. A trace of `SessionFile.resume/2` on a file with two integers of 400,000 digits gives 58 ms, equal to the JSON decode of the line, so the resume is not slow.
- These are the third set of findings on one mechanism: a check for each path in `consume/3`. The fix is on the mechanism. Every terminal leaves the provider Task through `cap_integers/1`, in one place. The tool call is a new struct of three fields. The `:DOWN` reason and `decode_usage/1` get the function. The cap in the catch-all clause of `consume/3` went away, because the Task exit covers it.
- Tests: a call struct and a `:done` map with an extra key in the session test, `error_int` and `refuse_int` providers, and the usage on resume.

The fix touches two code files. Round 4 is a full round.

## Simplify, fourth pass

One agent with the four angles.

- Reuse: clean. Simplification: no cap is redundant. The cap at the Task exit, the usage cap before `encodable?/1`, and the `:DOWN` cap each cover a path that the others do not.
- Efficiency, not applied: the copy in the map clause and the compare in the struct clause. Both are linear.
- Altitude, applied: the `@doc` of `cap_integers/1` listed each caller and went stale two times. Its last paragraph now names no call site, and the call sites hold the detail.

## Round 4, full round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Standards: 3 stale or contradictory statements, 6 judgement calls. No code violation.
  - The record of the fourth simplify pass, the `in the provider Task` sentence of the bounds row, and the `big_int` comment. Fixed.
  - Applied: the `:DOWN` cap in the devlog, the wording of the invariant for the Task exit, one documented exception for the marker in `usage`, `The function replaces`, and the order of the comments in the message test.
- Spec and failure path: 2 findings, the same two from each agent. Both are regressions of the struct clause of round 2. The earlier reproductions hold at 12 to 38 ms each.
  - A struct in place of the usage map, `usage: %Date{year: huge}`: the guard `is_map/1` accepts a struct, the function made it a string, and `map_size/1` in `SessionFile.encode_message/1` raised `BadMapError`. The session and the hands died with no `agent_end`.
  - A struct in place of the arguments map: the turn was correct, but the file held a string as `arguments`, and `Session.resume` rejected the file.
  - Fixed: the two guards in `consume/3` have `not is_struct(...)`. Arguments or a usage that are a struct are a malformed stream event. `cap_integers/1` returns a map for a plain map, so the type that the session file needs holds. The session test has both cases and a second prompt.
- Failure path, outside the ticket: `SessionFile.resume/2` with a session file line whose `type` is an integer of 400,000 digits takes 3,035 ms, because `check_entries/1` calls `inspect/1` on it, and the error holds the digits. The value is not from a provider and is not tool call arguments. It is older than this ticket. Ticket pending.
- Probed with no defect: prompts, steers, the model ref, and tool results accept only binaries. A resume with 400,000 digits in `usage` takes 38 ms.

The fix is 3 changed lines of code in one file, with no new function. The guards change which events `consume/3` accepts, so this is in doubt. Round 5 is a full round.

## Simplify, fifth pass

One agent with the four angles.

- Reuse, applied: the two guards use `is_non_struct_map/1` of the standard library.
- Simplification, not applied: the name `capped` for the capped usage, and a comment in `SessionFile` that a JSON decode gives no struct. Both are optional.
- Efficiency and altitude: clean.

## Round 5, full round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Standards: 0 violations, 3 judgement calls on wording. All applied: the `@doc` says `Callers apply this`, the entry point sentence says `stream events and terminals`, and the comment at the Task exit names the `:DOWN` handler.
- Spec and failure path: 1 finding, the same from each agent. It is a regression of the cap at the Task exit of round 3.
  - A `:done` payload that is a struct with the large integer in a field: the pattern in `consume/3` matched the struct, the cap at the Task exit made the whole struct the marker string, and `end_turn/2` raised `FunctionClauseError`. The session and the hands died with no `agent_end`.
  - Fixed on the shape, as for the tool call in round 3: `consume/3` builds the `:done` terminal as a new plain map of `stop_reason` and the capped `usage`. Each value that reaches `end_turn/2` now has a shape that session code made: this map, `{:error, reason}`, or `:stream_ended`. A test sends the struct and then a second prompt.
- Probed with no defect: the round 4 reproductions (31 ms, the session lives), two integer keys that both become the marker, an integer key and a real marker key, a usage with keys of each kind over the limit, the order and the count of the tool events, and `Session.resume` of a `big_int` session: 9 messages before and after, equal but for the usage keys, which the JSON round trip makes strings; that is older than #79.

The fix changes 2 lines of code in `lib/helyx/session.ex` and the text of one `@doc` in `lib/helyx/message.ex`. Two files are touched, so round 6 is a full round.

## Simplify, sixth pass

One agent with the four angles. One item, applied: the comment at the Task exit named the extra key of a `:done` map, which `consume/3` now drops. The comment and the bounds row name the error reasons and the malformed event. Reuse, efficiency, and altitude: clean.

## Round 6, full round

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

- Standards: 0 violations, 3 judgement calls on comments and one sentence of the bounds row. All applied.
- Spec: 0 defects, 0 missing requirements, 0 scope creep. 11 provider cases with 400,000 digits took 30 to 61 ms each, with no event over 10 KB, and the session accepted a second prompt each time. One doc gap, fixed: the slow `inspect/1` of `SessionFile.resume/2` is now in the documented exceptions.
- Failure path: 0 findings on the invariant.
  - Held: the struct `:done` payload, struct error reasons, a call id or name of a wrong type, a 3-tuple tool call event, a bad stop reason with the integer, a stream with no terminal after a rejected call, a rejected call as the only call, as the last call, and between two good calls with its id, the reset of `rejected` for the next provider call, and an abort with the session suspended while the terminal and the abort were in its mailbox.
  - A resume of a file with 1,000,000 digits in the arguments or the usage takes about 125 ms.
  - Outside the ticket: a file that a person changed, with 1,000,000 digits as the `content` of a message, makes `SessionFile.resume/2` take 18.8 s, because `Exception.message/1` formats the digits. It is older than this ticket. Ticket pending, with the `type` case of round 4.

The changes after round 6 are Markdown and comments in a test support file. No code changed, so no more rounds are necessary.

## Precommit

- First run: the root passed (1 property, 138 tests). `plugins/bundled` failed with 3 tests of `test/helyx/tool/read_test.exs`. They sent offsets of 5,000 and 100,000 digits through a session and expected the error text of the read tool. The session now rejects such a call before the tool. Fixed in the tests only: they use `10 ** 100 - 1`, the largest integer that the session gives to a tool, and a new test expects the session error for 100,000 digits in less than 2 s. No code changed, so no review round follows.
- Second run: passed. Root: 1 property, 138 tests, 0 failures, Dialyzer 0 errors. `plugins/bundled`: 184 tests, 0 failures, Dialyzer 0 errors. `apps/coding_agent`: 13 tests, 0 failures, Dialyzer 0 errors.
