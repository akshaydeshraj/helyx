---
name: hitl
description: Human in the loop. Ask the user every decision that parked tickets wait on, write the answers to the tickets, then start the orchestrator.
---

# HITL

The user is here now. Collect every pending decision, ask them, record the answers where the work lives, and hand back to `/orchestrate`.

## 1. Collect

`gh issue list --label ready-for-human --state open`. For each, `gh issue view <n> --comments` and take the last `## Decision needed` comment. A `ready-for-human` ticket without such a comment is asked as "What should happen with this ticket?" with its title and last comment as context.

Also list, without asking about them: tickets merged since the last devlog, and the escapes rows of that run. Two lines each at most.

## 2. Ask

Ask one ticket at a time, blockers of other tickets first. Say what the question is, what you recommend, and why, in a few sentences. Use `AskUserQuestion` with the options from the comment, recommended option first. The user decides; do not argue after the answer.

## 3. Record

For each answer, comment on the ticket:

```markdown
## Decision

<the answer, in the user's words where possible>, <date>.
```

Swap the label back to `ready-for-agent`. If the answer changes the ticket's scope or acceptance criteria, edit the ticket body too, so a fresh worker needs only the ticket. If the answer is "drop it", close the ticket as not planned and remove its worktree and branch.

## 4. Take off

When no `ready-for-human` ticket is left, or the user says to go, invoke `/orchestrate`. A parked ticket resumes in its kept worktree and branch, named in the State line of its comment.
