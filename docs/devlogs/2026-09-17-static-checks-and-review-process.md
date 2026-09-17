# 2026-09-17: static checks, property tests, and a stronger review process (ticket #19)

## The six escaped defects

Ticket #3 went through two full `/ship` review passes: simplify, then standards, spec, and failure path, twice. A human review of PR #18 and a Greptile run then found six defects. All are fixed on `master`; the record is `docs/reviews/2026-09-17-issue-3.md`. This ticket exists because of them.

1. **Parallel tool calls raced on one file.** Two edits from one assistant message ran in parallel Tasks and could overwrite each other. No axis probed concurrency between sibling operations; the failure-path brief listed per-operation probes (empty input, wrong shape, a crash mid-stream), and every probe ran one operation at a time.
2. **Trailing blank lines bypassed truncation.** `truncate/2` trimmed every trailing newline before counting, so `"a" <> "\n" x 60000` passed through whole. A boundary case of the input shape at a named limit; the brief named "empty input", not the boundaries of each limit, and no test held the line count at its limit.
3. **A cut line could be invalid UTF-8.** The byte cut landed inside a multibyte character. No brief and no test named a multibyte case.
4. **A line exactly at the byte limit was dropped.** An off-by-one in the separator count. Nothing tested at the limit, one under, and one over; the reviewers probed the values the brief suggested, which were all far from 51 200.
5. **Unbounded bash output.** The whole output buffered until the command exited, so `yes` grew the heap without bound. No axis asked what bounds a buffer; the spec axis checked the ticket's acceptance criteria, which named no resource bound.
6. **Unbounded file reads.** `read` and `edit` called `File.read/1` on any path, so `/dev/zero` blocked forever. Same gap as 5: resource bounds were nobody's category.

Why the passes missed them, across all six: the reviewers found only the class of failure their brief named, and the briefs listed probes instead of categories. The second-pass reviewers also read the review record and the author's fix summaries, so they verified the known defect list instead of hunting for new ones. And nothing static or automated checked style, specs, or limits, so reviewer attention was the only line of defense.

## Done

- Credo (strict, via `.credo.exs`) and Dialyzer run in `mix precommit` at the root. One Credo run covers `plugins/` through the `included` paths. Dialyzer cannot see plugin code from the root (plugins depend on the root, not the reverse), so each plugin's `precommit` alias runs its own `dialyzer`.
- StreamData is a test dependency. `Helyx.ToolTest` has the worked-example property test for `truncate/2`: for generated inputs that cross both limits from both sides, the output is valid UTF-8, within the line and byte limits, on whole lines, and the notice range matches the kept slice.
- The ship skill's failure-path brief now lists categories, not probes: input shape, the boundary at every named limit, resource bounds for every read, buffer, and wait, concurrency between sibling operations, and adversarial arguments from the model. The agent enumerates the cases. It gets the diff and the checklist only, never the review record or fix summaries. A dead review agent is rerun, never replaced by hand.
- The standards brief narrows to what Credo and Dialyzer do not cover: naming, AGENTS.md rules, and the smell baseline.
- `docs/agents/review-checklist.md` gains a "Specs and bounds" section: the feature doc bounds table, the limit test rule (at, one under, one over, multibyte), the `ponytail:` ticket rule, and the research citation rule. `docs/features/TEMPLATE.md` carries the bounds table and the citation slot; AGENTS.md points to it.

## Broke

- First strict Credo run: 13 findings. Two `with` misuses became a `case` and function clauses; the plugin test files gained a `Fake` alias. In `Helyx.Core` the same alias fix was a trap: the alias for `Helyx.Core.Plugins` expands inside `Module.concat(name, Plugins)` and silently renames the plugin registry. `Credo.Check.Design.AliasUsage` is disabled in `.credo.exs` for that reason.
- First Dialyzer run: one real finding. The test-support Kill tool returned `true` from `run/2` against the callback type, because `Process.exit(self(), :kill)` is the last expression and never returns. Resolved with `@dialyzer {:nowarn_function, run: 2}`; the brutal kill is the point of that tool.
- The first property test generator mixed the giant-line arm into the ~2000-line samples, so single samples reached megabytes and the property ran for over ten seconds. The giant line now appears only in small samples; big samples cross the byte total through medium lines.

## Next

- The remaining checkpoint-one tickets (#4, #5, #6, #8, #9) now run under the hardened process.
