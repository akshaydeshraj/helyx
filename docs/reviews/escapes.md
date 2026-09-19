# Escapes

One row per ticket that `/orchestrate` merged. An escape is a confirmed Codex finding: something `/ship` should have caught. The target is zero Codex findings in round one. The last column says what changed in the system so the class does not come back. A class that appears twice gets a mechanical check, not more prose.

| Date | Ticket | Ship findings per round | Codex findings per round | System change |
|---|---|---|---|---|
| 2026-09-19 | #38 | simplify 2, round 1: 11, round 2: 0 | round 1: 0 | none needed |
| 2026-09-19 | #50 | simplify 2, round 1: 12, round 2: 2 (docs) | round 1: 0 | none needed; an older defect found in review became #61 |
| 2026-09-19 | #58 | simplify 1, round 1: 4, round 2: 3, round 3: 2 older, not applied | round 1: 0 | none needed; the two-findings rule turned the decode heap into #64 instead of a second patch |
| 2026-09-19 | #51 | simplify 6, round 1: 7, round 2: 3 (tests and docs) | round 1: 0 | none needed; an older defect found in review became #68 |
| 2026-09-19 | #52 | round 1: 6, round 2: 2, round 3: 2, round 4: 5, round 5: 1, round 6: 1, round 7: 0 | round 1: 0 | none needed; the two-findings rule replaced the marker read with a per-call nonce; older holes became #70 and #71 |
| 2026-09-19 | #12 | round 1: 17, round 2: 5, round 3: 1, round 4: 5, round 5: 6 (tests and docs) | round 1: 1 rejected, 0 confirmed | the orchestrate skill now requires the invariant sentence to name documented exceptions |
| 2026-09-19 | #61 | simplify 2, round 1: 4, round 2: 1 (docs) | round 1: 0 | none needed; an older defect found in review became #75 |
| 2026-09-19 | #68 | r1: 2 simplify, 2 standards, 2 spec test gaps, 1 doc mismatch; r2: 2 spec, 1 failure-path, mechanism replaced; r3: 1 test gap | r1: 0 | none |
| 2026-09-19 | #75 | simplify 1; r1: 2 standards, 4 spec gaps; r2: 2 on the error text bound, mechanism replaced; r3: 3 gaps; r4: 0 | r1: 0 | the ticket named a `limit` argument that does not exist: a triage ticket must check that each named argument exists; older defects became #78 and #79 |
