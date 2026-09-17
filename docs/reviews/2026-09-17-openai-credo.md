# Review: OpenAI provider Credo fix

Scope: `fix/openai-credo`, one function extraction in `plugins/provider_openai/lib/helyx/provider/openai.ex`.

## Why

PR #23 merged without a rebase on #20, so the new Credo strict check never ran on it. Master failed precommit on one finding: `chunk_events/2` had cyclomatic complexity 10 against a limit of 9.

## Change

`delta_events/1` is extracted from `chunk_events/2`. Measured complexity after: 7 and 4.

## Simplify

The four angles ran as one agent on the 12-line diff. A one-token cut exists (`Enum.at(choices, 0, %{})`) but lands exactly on the limit, so the extraction was kept. No reuse, efficiency, or altitude findings.

## Standards

Clean. One nit applied: backticks around field names in the new comment.

## Spec

No behaviour change. Two coverage gaps predate the diff and sit on the extracted function: `reasoning` alone, and non-string delta fields. One test added for both.

## Failure path

All delta shapes hold: lists, numbers, maps, empty, null, both reasoning fields, multibyte, a 5 MB delta. One pre-existing finding, not introduced here: a `delta` or `choices` that is not a map or list raises in `Access.get` before `delta_events/1` runs, so the turn fails with `{:task_exit, _}` instead of `{:error, {:bad_chunk, _}}`. The session survives. Follow-up: guard the chunk shape in `chunk_events/2` and return the bad-chunk error.
