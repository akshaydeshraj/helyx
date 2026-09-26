# Orchestrate run of the boundary review

Date: 2026-09-26. The run built the tickets of the boundary review (`docs/reviews/2026-09-26-boundary-review.md`), #140 to #146, and the two open items from the Core cleanup run, #129.

## Before the run

- T0 went in directly as c9fec48: the boundary rules in `AGENTS.md` ("Elixir guidelines"), the "Boundaries" section of `docs/agents/review-checklist.md`, the boundary probe in the `/ship` failure-path brief, the rejection rule of `/orchestrate` for a finding that enters below a boundary, and the "where enforced" column of the Bounds table in `docs/features/TEMPLATE.md`.
- The review record went in as a17382b.

## Decisions of the owner

- #143: delete both E1 (the catch-all `handle_info/2` of the session) and E3 (the UTF-8 check on the id of an external tool result).
- #144: repair tool text at two boundaries, the hands and the stream, not in one shared helper.

## Merged

| Ticket | PR | Codex rounds |
|---|---|---|
| #140 the `cwd` boundary at session start | #147 | r1: 0 |
| #129 the reader keeps the chat when an optional value on resume is bad | #149 | r1: 0 |
| #141 the harness providers check for perl | #151 | r1: 1, r2: 0 |
| #142 the tool specs are checked once at session start | #154 | r1: 1, r2: 0 |
| #143 inner defensive code deleted | #155 | r1: 0 |
| #144 tool text repaired at the two boundaries only | #156 | r1: 0 |
| #145 a `/model` notice for a provider with a bad `turn/0` | #157 | r1: 0 |

## Parked

- #146: one tool call with bad JSON arguments fails the whole OpenAI turn. The fix is a new provider stream event, so a feature doc comes first. The draft proposes `{:rejected_tool_call, call, reason}` for a local turn, and one rejection path in Core for this event and the integer cap. It waits for the approval of the owner.

## Filed

- #148: the `mix helyx` not-a-directory error prints the raw argument.
- #150: the tool `check/0` runs after the session file is created or repaired.
- #152: follow-ups from #141: NUL bytes and raw bytes that reach the program start and its error text.
- #153: `Helyx.Provider.find/2` calls `id/0` with no catch.
- #158: `CodingAgent.error_text/1` prints `{:bad_provider_turn, id}` as a raw tuple.

## Escapes

| Ticket | Codex finding | System change |
|---|---|---|
| #141 | `open_port/2` rescued `in ErlangError` and read `error.original`. A normalized exception, such as `SystemLimitError` at the port limit, has no such field, so the rescue raised `KeyError`. | `docs/agents/review-checklist.md`, Tools and hands: format a caught exception with `Exception.message/1`. |
| #142 | A tool spec callback that raised, threw, or exited reached the caller of `Session.start/2` and `resume/2`. On master, the start returned an error. | `docs/agents/review-checklist.md`, Inputs from plugins: contain every plugin callback that runs in the caller of a start or resume, and the plugin code that the check of its value runs. |

Both escapes are on the same class: a failure of code this module does not control, at a boundary. Neither class had an earlier row in `docs/reviews/escapes.md`, so no mechanical check was added. A second escape of either class gets one.

## Orchestrator checks that changed a result

- #142: the worker let a raising spec callback propagate to the caller (its decision 4). Codex found the same case as a regression, and it was rejected: plugin output into Core is a boundary. The fix contains raise, throw, and exit in the style of `Helyx.Provider.turn/1`. An exit signal from a process that a callback linked to the caller is not contained, as in `turn/1`; this was accepted, because plugins are compiled into the node.
- #143: one extra ViewModel test was deleted, which the ticket did not name. It tested only the guard and the catch-all that A3 deletes, so it was accepted.

## Notes

- #141 needed 7 full `/ship` rounds before Codex (2, 2, 2, 1, 3, 1, 0 findings) for a library diff of about 111 lines. Most findings were on the spawn error path of the watchdog. A ticket that changes how an external program starts can expect more rounds.
- The bounds sensor did not run in any ticket, because `TYPESAFE_API_KEY` was not set.

## Next

- The owner approves or changes the #146 feature doc.
- Triage #131, #148, #150, #152, #153, and #158. #150 and #153 are small and follow the pattern of #142.
