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

## Out of scope

What this feature deliberately does not do, and which ticket owns it.
