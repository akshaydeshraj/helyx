# Review: bound the steer and follow-up queues (#29)

Scope: the working tree for ticket #29. Cap each session queue at 32 entries,
reject past the cap with `{:error, :queue_full}`, keep rejected text in the
TUI composer, and record the bound in the feature doc.

## Round 1 (full: simplify, standards, spec, failure-path)

Simplify (4 agents):

- Cap in three `handle_call` clause heads instead of the shared `queue/3`
  funnel. Fixed: the cap moved into the funnel.
- Redundant `@queue_limit` comment. Fixed: removed.
- Cached queue counters. Skipped: the agent judged the cost immaterial.

Standards:

- `:erlang.map_get` guard against the pattern-matching rule. Fixed: two
  pattern-matched `queue_reply/3` accept clauses plus a reject clause.
- `if sent == :ok` in the TUI. Fixed: a `case` over the send result.
- `queue/3` named as a state helper but returning a reply tuple. Fixed:
  renamed to `queue_reply/3`.
- Overclaiming funnel comment. Fixed: removed.

Spec:

- No tests at the limit, one under, one over, multibyte, and no assertion
  that a reject emits no `queue_update`. Fixed: the suite test covers all.
- "Entry text unbounded" clauses lacked a ticket citation. Fixed: cite #29.
- Rejection invisible in the TUI. Accepted: needs view-model and render
  work; filed as issue #46.

Failure-path: no defects. Boundaries, independence of the two queues, abort
re-arm, and no-event-on-reject all reproduced green in scratch tests.

## Round 2 (full: fix touched two code files)

Fix diff without tests and Markdown: about 17 lines over
`lib/helyx/session.ex` and `plugins/tui/lib/helyx/tui.ex`, so a full round.

Simplify (4 agents): three suggestions, all skipped. Collapsing the twin
`queue_reply/3` clauses and reverting the TUI `case` contradict the
documented pattern-matching standard; dropping the test's event drain would
break the selective `refute_receive`.

Standards: prior fixes hold, no hard violations. Judgement calls fixed:

- Wildcard reject clause would return `:queue_full` for a typoed key. Fixed:
  guard `key in [:steers, :follow_ups]` so a bad key crashes.
- TUI reject branch untested. Fixed: "a rejected send keeps the composer
  text" in the TUI suite, holding the turn open with an in-file slow tool.

Spec:

- Same untested TUI branch. Fixed as above.
- Bounds row wrongly said `:queue_full` comes from the client boundary.
  Fixed: the session returns it.
- Pre-existing bounds-table gaps for tool, hands, and provider limits.
  Out of this diff; filed as issue #47.

Failure-path: no defects. A 64-caller race yielded exactly 32 accepts, and
resume cannot pre-fill a queue.

## Round 3 (reduced: fix was 1 code line in 1 file)

Spec: all round-2 fixes hold. The #46 deferral was uncited in the feature
doc; fixed with a ticket citation (Markdown only). The guard list on a
private function was called minor unreachable defense; kept, it is one line
and makes the crash loud. A comment nit ("bad UTF-8" unreachable from the
TUI call site) skipped: the branch still guards that return by design.

Failure-path: no defects. Reject-then-drain, seq gaplessness across a
reject, funnel completeness, bad-key crash, and single-process concurrency
all reproduced green.

## Resolution

Cap of 32 per queue in `queue_reply/3`, loud on bad keys, tested at the
boundary in both suites. Follow-ups: #46 (visible rejection feedback), #47
(missing bounds-table rows).
