# Review: OpenAI provider bad-chunk shape gate (issue #33)

Scope: `plugins/provider_openai/lib/helyx/provider/openai.ex` and its test.
The change adds one shape gate in `data/2` and a `:halted` accumulator state,
so a decoded chunk with the wrong shape ends the stream with one
`{:error, {:bad_chunk, payload}}` event instead of a raise.

## Round 1 (full: simplify, standards, spec, failure-path)

Confirmed findings and resolutions:

1. **Gate hole (simplify, reproduced).** `{"choices":[{"delta":{"tool_calls":[{"function":"x"}]}}]}`
   passed the gate and raised in `add_call_delta/2`. A non-binary
   `function["arguments"]` could also raise later, at flush. Fixed: the gate
   checks each call's `"function"` map and that `"arguments"` is nil or a
   binary. Two test rows added.
2. **Clause order (simplify).** The `handle/2` `:halted` clause sat below the
   `{:error, _}` clause, so a transport error after a bad chunk leaked
   through. Fixed: the `:halted` clause is first. The order is load-bearing.
3. **Untested chunk-level halt (spec).** The only multi-event test packed all
   lines into one binary, so `handle(_chunk, :halted)` had no coverage.
   Fixed: the test delivers `[DONE]` in a second chunk.
4. **Overclaiming gate comment (standards, spec, failure-path).** The comment
   said everything below the gate accesses fields without guards; false.
   Fixed: reworded (see round 2).
5. **Test duplication (simplify).** Generated tests hand-built the SSE line;
   they now use the `sse/1` helper.

Skipped, with rationale:

- **Replace the gate with `rescue`** (simplify, spec). The ticket's
  acceptance criterion mandates a shape check, and a rescue would mask the
  parser's own defects as peer errors.
- **`case` on field lookups is a standards violation** (standards). Judged a
  false positive: the documented rule opposes conditional logic, not `case`
  pattern matching, and the module already used the construct
  (`session_header/1`).
- **`valid_call?` is scope creep** (spec). Kept: both extra shapes were
  reproduced raises, the defect class the ticket exists to kill. The
  ticket's out-of-scope category is wrong-typed fields that cannot raise.
- **Single-walk `shape/1` refactor and outer halt combinator** (efficiency,
  altitude). The double field walk is a few map reads next to a
  `JSON.decode`; the sentinel version is smaller and verified.

## Round 2 (reduced: spec, failure-path)

Fix under review: the round-1 test split and comment fix. Counts: 4 changed
lines in one code file, no function changes, so a reduced round.

- Failure-path: clean across 8 probed cells (splits, buffers, multibyte,
  transport error after halt).
- Spec: the rewritten comment still overclaimed ("rejects exactly the shapes
  that would raise"; `arguments: 42` coerces, `data: null` and a junk-choices
  error chunk are rejected but would not raise). Second finding on the same
  mechanism, so the fix targeted the mechanism: comments now make only
  one-directional claims.

## Round 3 (reduced: spec, failure-path)

Fix under review: two reworded comments, one code file, no executable change,
so a reduced round.

- Spec: clean. All round-2 counterexamples land inside the new wording; no
  shape passes the gate and still raises.
- Failure-path: clean. Adversarial sweep of gate-passing shapes through
  flush found no raise.

Loop ended: round 3 changed nothing.
