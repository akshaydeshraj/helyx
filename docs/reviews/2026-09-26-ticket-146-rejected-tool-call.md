# Review: rejected tool call (#146)

Date: 2026-09-26. Base: `origin/master` at 0dbda32. Ticket #146, finding D4 of `docs/reviews/2026-09-26-boundary-review.md`. Spec: `docs/features/rejected-tool-call.md`.

## Invariant

`Helyx.Session.Stream` is the boundary of the new provider event `{:rejected_tool_call, call, reason}`. The event passes only on a local turn, with a reason that is valid UTF-8 of at most 1,024 bytes and a call that passes the checks of `{:tool_call, _}`. Other events fail the turn with `{:bad_stream_event, event}`. A call that passes goes into the assistant message in stream order, never runs, and gets `{:error, "tool call not run: " <> reason}` through the path of a result from the hands. The integer cap uses the same path with its reason. In `Helyx.Provider.OpenAI`, arguments that are not a JSON object give the event for a call with an id, and `{:bad_tool_arguments, name}` for a call with no id. No event and no error holds the raw JSON.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (4 agents): reuse 0, simplification 3, efficiency 0, altitude 1.

- Fixed: `Turn.rejected` is a map from call to reason, not a list of pairs with `List.keyfind/3`.
- Fixed: `tool_call/5` in `Stream` rebuilds the event of a malformed call with `call_event/2`, not with a closure argument.
- Fixed: the `:rejected_call` clause of `Session.Server` binds the turn in its head.
- Skipped (altitude, also standards in round 1 and 2, and altitude in round 2): pass the original event to `tool_call/5` and remove `call_event/2`. The rebuilt event holds the checked call: a new struct with the capped arguments. The original event can hold a struct with more keys. The error shape stays the same as before this change.

Standards: 2 hard findings, 4 judgement calls.

- Fixed: the reason bound had no test one under the limit and no multibyte case. Tests now cover 1,023, 1,024, and 1,025 bytes, and 512 "é" (1,024 bytes) with and without one more byte.
- Fixed: the `Turn` comment said "empty list".
- Fixed: the `Stream` comment said "a call the provider could not decode"; the contract is wider.
- Skipped: the literal `"tool call not run: "` is in `run_tool/2` and in the `Helyx.Provider` moduledoc. Code has one copy.
- Skipped: the Goal of the approved feature doc has the words "in proportion". The design doc does not change.

Spec: 0 blocking findings.

- Fixed: the stream test of the integer cap matched the reason with `_`. It now asserts the reason text.
- Accepted: `docs/features/session-stream.md` names the new message shape, which the spec does not list. Without the change the line is wrong.
- Accepted: the render path. The result text is at most 1,043 bytes and takes the normal tool result path; the TUI cuts each line at 8,192 bytes.

Failure-path: 0 findings. Noted: a good call that is equal in value to a rejected call is also not run. This is the documented rule of `Turn` for the integer cap.

## Round 2 (full)

The fix changes two comment lines in two code files, so the round is full.

Simplify (4 agents): reuse 0, simplification 1, efficiency 0, altitude 1 (the skipped `call_event/2` item).

- Fixed: the UTF-8 check of the reason moved into the existing `Message.encodable?/1` check of `tool_call/5`; the consume clause has no branch of its own.

Standards: 0 hard findings, 4 judgement calls.

- Fixed: the test models `reject_multibyte_512/513` are now `reject_multibyte_1024/1025`, as the byte names of `reject_bytes_*`, and their comment is correct.
- Fixed: a `Stream` comment now says "checks that it is valid UTF-8".
- Skipped: `call_event/2` (see round 1), and the `{:halt, malformed(...)}` branch next to `forward/5`: the rejection must go to the session between the check and the forward.

Spec: 0 findings. Noted: two integer cap assertions changed shape (the four-element message, `Turn.rejection/2`), because the spec changes the message. The session test of the integer cap did not change.

Failure-path: 0 findings. Probes through `Stream.run/1`: an empty reason, 1,024 bytes that end with an invalid byte, a struct as arguments, an integer id, a bare map as the call, a four-element event, and a rejected call with an integer of 200 digits. Each gave the result of the invariant.

## Round 3 (reduced)

The fix changes one comment line in one code file and renames two test models. It adds no function and changes no spec, so the round is reduced: spec and failure-path.

Spec: 0 findings. The renamed tests cover the reason bound at 1,023, 1,024, and 1,025 bytes, and the multibyte case.

Failure-path: 0 findings. Probes through `Stream.run/1`: an external turn, an id that is `<<255>>` or nil, an argument value `<<255>>`, a surrogate as the reason, a call struct with one more key, 1,024 NUL bytes. Each gave the result of the invariant.

## Precommit

`mix precommit` passed in the root, `plugins/bundled`, and `apps/coding_agent`, after round 2 and again after round 3.
