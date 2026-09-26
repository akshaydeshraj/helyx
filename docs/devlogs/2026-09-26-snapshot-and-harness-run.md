# 2026-09-26: snapshot and harness run

The second orchestrate run of the day. It started after the triage of #167, #169, and #170, and it ended when checkpoint one (#1) closed.

## Merged

| Ticket | PR | Change |
|---|---|---|
| #169 | #179, record fix #180 | Core fails at start on an invalid or a duplicate provider id |
| #170 | #181 | The TUI `:DOWN` clause matches only the monitor it stored |
| #167 | #185 | A write to a dead harness port fails the turn; the Claude Code stream Task no longer traps exits, and a keeper holds the port link |
| #163 | #186 | `Session.subscribe/1` returns a snapshot valid at a `seq`; the TUI mounts from it |

Doc PRs: #178 and #183 (the snapshot feature doc), #182 (research on client protocols, agent UI protocols, and a SwiftUI client).

No ticket was parked.

## Owner decisions

- #163: `turn.running` holds the started calls with no result (option 1). The notice "resumed session" shows only after `--resume`. A snapshot does not rebuild notices or the partial reply of an aborted or failed turn. A call that never started shows a closed `aborted` cell in the snapshot only.
- #167: a write failure fails the turn with the same error shape as other harness failures. The keeper, not the stream Task, now traps exits; the result is the same.
- #65 and #25 closed as not planned. #1 closed after #163; story 42 was reversed by ADR 0005, and story 35 is deferred to #116.

## Escapes

| Ticket | Codex | System change |
|---|---|---|
| #170 | r1: 1, r2: 0 | Checklist: a test that monitors a process it just spawned uses `spawn_monitor/1` |
| #167 | r1: 1, r2: 1, r3: 0 | The same class twice in one ticket, so a structural fix: the stream Task does not trap exits. Checklist: a Task that a shutdown must end at once does not trap exits |
| #163 | r1: 0 (older commit), r2: 1, r3: 0 | Checklist: a snapshot rule is checked against every writer of the transcript |

#169 had no Codex finding.

## Findings

- A killed sessions Registry stops Core with `:shutdown` (recorded on #116).
- New ticket #184: the Codex provider still traps exits for its graceful interrupt, so a hands shutdown can wait up to the 2,000 ms kill.

## Next

- A draft ADR, "client contract", is under review by the owner. It proposes a closed list of client operations, an end signal, an item model with session ids aligned to ACP v2, and a `contract_version`.
- #184 needs triage.
