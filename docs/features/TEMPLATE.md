# <Feature name>

Copy this file to `<slug>.md` and fill it in before the implementation. Review checks it against the diff (`docs/agents/review-checklist.md`, "Specs and bounds").

## Goal

What the feature does and why. A design decision that the tools research (issue #17) covered cites it here, so review can check the design against how codex, opencode, and pi behave.

## Interface changes

The behaviours, public functions, and event shapes this feature adds or changes.

## Bounds

Every input, buffer, and wait, with its bound. A bound that does not exist yet is written as "unbounded, ticket #N", never left out.

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| example: tool output | 2000 lines or 50 KB | cut on whole lines, the result says so |

Every numeric limit in this table gets a property test or, at minimum, tests at the limit, one under, one over, and a multibyte case. Every `ponytail:` marker in the implementation names a ticket.

## Ownership

Every external resource the feature touches (OS process, process group, port, file handle, socket, temp file) gets a row. A release cell that is a race is written as "open, ticket #N", the same vocabulary as an unbounded input, never left out (see ADR 0004).

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| example: command process group | bash tool launcher | hands | hands kill on delivery | hands kill on delivery of the crash result | hands kill on cancel |

A row whose holder is a Task is a design flag: the spec axis raises it before implementation, because a Task dies with its state and takes the only reference to the resource with it.

## Out of scope

What this feature deliberately does not do, and which ticket owns it.
