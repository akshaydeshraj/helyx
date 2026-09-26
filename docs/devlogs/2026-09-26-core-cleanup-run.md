# Orchestrate run of the Core cleanup

Date: 2026-09-26. The run built the tickets of the Core cleanup plan (`docs/reviews/2026-09-26-core-cleanup-plan.md`), #117 to #126.

## Decisions of the owner

- #123: one flag named by behaviour, `turn/0` with `:local` or `:external`, in place of four separate capabilities. The steer on an external turn does not change. The `harness_session` data names stay, because they are the session file format and the event contract. The feature doc `docs/features/external-turn.md` and the ADR 0002 revision text were approved before the ticket went to `ready-for-agent`.

## Merged

| Ticket | PR | Codex rounds |
|---|---|---|
| #117 interface and data shape files in folders | #127 | r1: 0 |
| #126 `Fake.run_tool/3` to the test support of `plugins/bundled` | #128 | r1: 0 |
| #118 stop-reason set and harness id rule to `Helyx.Message` | #130 | r1: 0 |
| #119 `Queues`, `Turn`, and `Transcript` out of the session | #132 | r1: 0 |
| #120 `Helyx.Session.Stream` runs the provider call | #133 | r1: 0 |
| #122 context and compaction plugins resolved once per session | #134 | r1: 0 |
| #121 tool text helpers to `Helyx.Text` | #135 | r1: 0 |
| #123 the provider turn named by behaviour | #136 | r1: 0 |
| #125 one layer for the watchdog calls of the harness providers | #137 | r1: 0 |
| #124 `Session` and `Server` split, runtime in `session/` | #138 | r1: 0 |

The mechanical `mix helyx.graph` task went in directly as 70f30f1, by the choice of the owner.

## Parked

None.

## Filed

- #129: the session file does not check the harness id on write in `append_harness_session/3`.
- #131: the bash test "a watchdog killed before the go-ahead" is flaky and exits with `:epipe`.

## Escapes

None. Every ticket had a clean first Codex round, so no system change was made.

## Orchestrator checks that changed a result

- #121: the worker made Core enforce only the byte bound (65,536 bytes) on a harness tool result. The 2000-line bound is now a provider contract, which ClaudeCode and Codex keep with `Helyx.Text.truncate/2`. This follows the approved feature doc, so it was accepted.
- #123: the rebase onto #121 had two conflicts. In `stream.ex`, the #121 bodies were kept under the #123 function name. Git moved the new `provider_test.exs` to a wrong directory because of the rename of `tool_test.exs`; it was put back at `test/helyx/interfaces/`. Precommit passed after the rebase.

## Next

- Triage #129 and #131.
- A follow-up candidate from #124, not filed: the client builds `%Helyx.Session.Server.State{}`. A keyword `start_link/1` would move the plugin lookup into the session process, which is a change of behaviour.
