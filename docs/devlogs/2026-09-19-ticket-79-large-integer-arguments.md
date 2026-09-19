# Ticket #79: a very large integer in tool call arguments makes the turn slow

Date: 2026-09-19. Branch `ticket/79-large-integer-arguments`.

## Done

- Traced the slow call. The JSON encode of the integer is the slow step, not the decode. The numbers are in `docs/reviews/2026-09-19-ticket-79-large-integer-arguments.md`.
- The encode ran in three places: the stream check of the session (`Message.encodable?/1` in `consume/3`), the session file append in the session process, and each later provider request.
- Added `Helyx.Message.cap_integers/1`. It replaces each integer of more than 100 digits with a marker string. The walk covers maps with their keys, lists, tuples, and structs.
- The stream boundary of the session applies it before the first encode: to the arguments of a tool call, to the usage, and to every terminal that leaves the provider Task.
- The `:DOWN` handler of the session applies it to the reason of a Task exit.
- Arguments or a usage that are a struct are now a malformed stream event.
- The session gives a call whose arguments changed an error tool result and does not run the tool.
- The session file applies the function to the arguments and the usage on resume, for a file from before this fix.
- Added the bounds row `Integer in tool call arguments and in the usage of a provider call` to `docs/features/coding-agent.md`.

## What broke

- The first version walked the arguments two times: in the provider Task and in the session process. The first simplify pass moved the walk to the Task only.
- Round 1: a good call with the id of a rejected call did not run, an integer map key passed, and the `usage` map had no limit.
- Round 2: a struct passed the walk (`Date` with a large year), and `inspect/1` of an error reason with `{huge}` took 3 s.
- The third simplify pass: the reason of a malformed event had no cap.
- Round 3: an extra key of a `:done` map or of a tool call struct, and an error reason from a provider, held the integer. Now every terminal leaves the Task through the function.
- Round 4: a struct in place of the usage map became a string and crashed the session in the file encode. A struct in place of the arguments map made a file that resume rejects. Both were regressions of the struct clause. The stream check now rejects them.
- Round 5: a struct as the `:done` payload became the marker at the Task exit and crashed the session in `end_turn/2`. `consume/3` now builds the `:done` terminal as a new plain map.
- Precommit: three read tool tests sent offsets of thousands of digits through a session. They now use the largest integer that the session passes, and a new test expects the session error.

## Next

- Ticket pending: `SessionFile.resume/2` calls `inspect/1` on a bad entry `type`. A file that a person changed, with an integer of 400,000 digits as the `type`, makes the resume take 3 s, and the error holds the digits. With 1,000,000 digits as the `content` of a message the resume takes 18.8 s, because `Exception.message/1` formats the digits.
- Ticket pending: a provider that raises or exits with a large integer in the reason. The crash report of the Task formats the digits.
- Ticket pending: an integer of more than about 1,262,611 digits makes `JSON.decode/1` raise `SystemLimitError` in `Helyx.Provider.OpenAI`. The provider Task exits and the turn fails. The fix is in the provider.
