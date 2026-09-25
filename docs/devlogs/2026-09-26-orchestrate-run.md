# Orchestrate run after the HITL of 2026-09-25

Date: 2026-09-25 to 2026-09-26. The run started after `/hitl` recorded the decisions on #10, #64, and #44.

## Decisions of the HITL

- #10: Esc on a Claude Code turn waits until the process group is gone. A fresh harness session gets a replay of the Helyx history, also after a switch from another model. The permission mode is `bypassPermissions`. The replay replaced "start fresh" after a real `claude` run showed that `assistant` lines on stdin are accepted with no model call.
- #64: the resume decode runs under a heap cap of 1 GiB.
- #44: Enter sends, Ctrl+J adds a line, Shift+Enter adds a line where the terminal reports it, and a paste of more than 5 lines shows as one marker.

## Merged

| Ticket | PR | Codex rounds |
|---|---|---|
| #100 OS release of process groups into the bash plugin | #102 | r1: 0 |
| #64 heap cap of the resume decode | #107 | r1: 0 |
| #44 multiline composer with paste markers | #109 | r1: 0 |
| #10 Claude Code harness provider | #110 | r1: 1; r2: 1, rejected |
| #11 Codex harness provider | #113 | r1: 1; r2: 0 |

## Parked

None.

## Filed

- #103: the session supervisor keeps a copy of the resumed transcript.
- #104: `Session.resume/2` can repair the file and then fail on an unknown model.
- #105: no client can read the restored transcript.
- #106: the JSON decode of the OpenAI provider has no heap cap.
- #108: Shift+Enter needs the kitty keyboard protocol, which `ex_ratatui` does not have.
- #111: the events and messages of one harness turn have no bound.
- #112: an abort of a harness turn drops tool results that finished before it.

## Escapes

| Ticket | Codex finding | System change |
|---|---|---|
| #10 | An interrupted replay let the next turn resume the new harness session id, so history was lost with no notice. | `docs/agents/review-checklist.md`, Sessions and turns: an id of outside state is reused only when that state has received everything, with a state table for its life. |
| #11 | Queued stdout kept `receive` from its `after` clause, so the exit deadline never fired. The same bug was on master in the Claude Code provider. | `docs/agents/review-checklist.md`, Races: a `receive` loop with a deadline checks it before each `receive`. |

The rejected finding of #10 round 2 claimed that the `aborted` result Helyx adds never reaches Claude Code. A real run showed that Claude Code closes the open call of a killed run by itself. The fact is in `docs/research/claude-code-stream-json.md`.

## Orchestrator checks that changed a result

- #44: the worker listed a paste that is dropped with no notice as an accepted hole. The ticket says "nothing is changed in silence", so the marker became one unit for every edit.
- #11: the worker's 500 ms grace before the KILL was equal to the cleanup time of codex that its own research measured. That goes against "wait until all is stopped". The grace is now 5,000 ms. An accepted hole must not contradict an acceptance criterion or a measured number.

## Next

- Triage #103 to #106, #108, #111, and #112.
- #101, the bound on the handles per Task, still has the `needs-triage` label.
