# Triage and cleanup run

Date: 2026-09-26. The run triaged the open issues from the boundary review run and the older backlog, then built the tickets that came out of it. It also built two tickets from a ponytail review of the tree.

## Decisions of the owner

- #150: run the tool checks before the session file is created.
- #153 and #158: one ticket.
- #148: show the bad argument with `inspect`.
- #131: fix it in the code.
- #103: first a garbage collection of the session supervisor. A failure-path probe of the worker disproved the mechanism, and the owner then chose `hibernate_after: 0` only.
- #111: cap the Codex held events at 10,000. The ticket also took the doc rows of #101, #106, and #112.
- Ponytail review: keep `mix helyx.graph`; keep the plugin table in `Registry` meta (#165). Rejected: deleting `Compaction.None`, `Message.Image`, `parent_id` and `leaf` (ADR 0001), the `cwd` NUL check in bash, and the release delegates.
- #115 stays a tracker with no label. #116 waits for the transport work.

## Merged

| Ticket | PR | Codex rounds |
|---|---|---|
| #150 the tool checks run before the session file | #166 | r1: 0 |
| #153 provider ids are contained; #158 the provider turn error text | #168 | r1: 0 |
| #148 the `mix helyx` argument errors | #171 | r1: 1, r2: 0 |
| #131 the fix in code | #172 | r1: 0 |
| #103 the session supervisor hibernates after each message | #173 | r1: 0 |
| #165 the plugin table in `Registry` meta | #174 | r1: 0 |
| #111 the Codex held events cap, and the doc rows of #101, #106, #112 | #175 | r1: 0 |
| #164 unused API and duplicate code deleted | #176 | r1: 0 |

## Parked

None.

## Closed without code

- #101, #106, #112: their doc rows went into #111.
- #104: harmless; closed with the reason.
- #105: the doc fix now; the feature is #163.
- #108: closed by the owner.
- #152: closed; its one open item became #162.
- #162: closed. The finding was wrong: the probe called `Port.open` directly, and `Helyx.Tool.Bash.run` already rejects a NUL byte. Its ADR fix went into #150.

## Filed

- #163: the feature of #105. It needs a feature doc (`ready-for-human`).
- #164 and #165: from the ponytail review. Both merged in this run.
- #167: EPIPE on a write after the go-ahead.
- #169: check the provider ids at Core start.
- #170: the TUI `:DOWN` clause matches any monitor.

## Escapes

| Ticket | Codex finding | System change |
|---|---|---|
| #148 | `OptionParser.parse/2` raised `ArgumentError` on the argument `-=`. | `docs/agents/review-checklist.md`, Boundaries: a parser library can raise at a boundary, so contain its exceptions by name and probe with generated input. |

The first Codex run of #148 failed: its invariant sentence held a switch name that starts with `--`, and the review script read it as its own option. `.claude/skills/orchestrate/SKILL.md` now says to name switches in words in that sentence.

## Corrections

- The #153 review record says that the provider id check at Core start goes to #165. It went to #169. #165 is the `Registry` meta change.

## Notes

- #153 took 8 `/ship` rounds and #131 took 7 before Codex. Both had clean Codex rounds.
- #111: the ticket text had two wrong facts. A Claude Code Task can hold 4 handles, not 2 (#101). A held Codex result does not show as `aborted` (#112). The docs state the code.
- #111: the cap counts events, not bytes. The held volume is bounded by 10,000 events of at most 16 MiB each and by the user abort. A byte cap needs a new decision.
- #164: the #103 supervisor test (`test/helyx/session_test.exs:1007`) failed once in the worker's first round and did not fail again.
- The bounds sensor did not run in any ticket, because `TYPESAFE_API_KEY` was not set.

## Next

- Triage #167, #169, and #170.
- Write the feature doc for #163.
