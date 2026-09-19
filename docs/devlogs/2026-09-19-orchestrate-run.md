# 2026-09-19: orchestrate run

The first run of `/orchestrate` with no person in the loop. It ended with an empty frontier.

## Merged

All issues closed through a PR with `Closes #n`.

| Ticket | PR | Change |
|---|---|---|
| #68 | #77 | the byte cut keeps a whole character at the edge |
| #75 | #80 | the read tool rejects an offset that is not an integer |
| #70 | #81 | the bash watchdog reports its start |
| #67 | #82 | a start failure of the agent prints one sentence |
| #74 | #84 | the TUI rejects event text that is not valid UTF-8 |
| #71 | #85 | the launcher removes `PERL*` variables from the watchdog |
| #46 | #86 | the status bar shows the reason of a rejected input |
| #62 | #87 | the session scan reads at most 256 files |
| #78 | #88 | an offset after the last line is an error |
| #83 | #89 | a tool result attaches to its cell by `tool_call_id` |
| #79 | #91 | integers of more than 100 digits are removed from messages |
| #40 | #92 | the TUI wraps by display width |
| #47 | #94 | bounds rows for the `:infinity` waits and the receive timeout |
| #93 | #96 | client calls answer during the abort sweep |
| #95 | #97 | an unknown message does not stop the session |
| #39 | #98 | transcript scrollback |

Earlier in the same session: #38, #50, #58, #51, #52, #12, #61.

## Parked for `/hitl`

- #10, Claude Code harness provider. Five questions in its `## Decision needed` comment: the provider contract, a twelfth event, the harness stream as a hands Task with a shared watchdog module, two gaps in the feature doc, and the `--permission-mode` value. The branch `ticket/10-claude-code-harness` holds the session file part.
- #44, multiline composer. Recommended: Enter sends, Ctrl+J makes a new line.
- #64, heap use of the resume decode. Recommended: a parse process with `:max_heap_size` of 1 GiB.
- #11 waits for #10. #90 waits for a width function in ExRatatui. #25 and #65 stay `wontfix`. #1 stays open until #10 and #11 are done.

## Escapes and system changes

The rows are in `docs/reviews/escapes.md`. Codex found a confirmed defect in three tickets: #70 (a wide character in the report write), #74 (an older defect, filed as #83), and #39 (a frame before `Resize` wrapped every cell). The rules that came from the run are now in `.claude/skills/orchestrate/SKILL.md`:

- A ticket names only items that exist. The worker checks each named item first. Source: #75 named a `limit` argument, #40 named `:string.width/1`.
- A brief forbids a print of the machine environment. Source: #71.
- The invariant sentence names its entry points and the accepted holes. Source: #67, #95.
- Search the tree for `ticket pending` before each merge. Source: #83.
- A worker reports a wider scope when a fix passes 100 code lines. Source: #79.
- A stopped worker is resumed with SendMessage, not started again. Source: #78.
- Each merge step runs only when the step before it passed. Source: #83.
- A bound that holds at the entry points must also hold in the render path. Source: #39.

## What broke

- **Possible credentials in a local transcript.** In #71 one failed assertion printed the machine environment into the local session transcript of the worker. Two values look like credentials. They are not in the repository, a commit, or a PR. The user decides about rotation.
- A usage limit (HTTP 429) stopped two workers and their review agents. They continued after the reset.
- A TLS timeout broke `gh pr create` for #83. My cleanup was joined with `;`, ran early, and removed the worktree. The branch was on the remote, so nothing was lost.
- A `ticket pending` phrase from #71 reached master. The #83 branch corrected it.
- Four perl watchdog processes from an older worktree are still alive: 55586, 55589, 56296, 56306.

## Next

`/hitl` for #10, #44, and #64. Then #10 and #11 complete checkpoint one.
