---
name: ship
description: The only way to commit in this repo. Simplify, review on three axes, run precommit, then commit.
---

# Ship

Every commit goes through this skill. Run the steps in order. Do not skip a step because the diff is small. A change that touches only Markdown skips steps 1 and 2.

## 1. Simplify

Invoke `/simplify` on the working tree changes. Apply its fixes. Simplify is bug-blind by design, so anything it touches is reviewed again in step 2.

## 2. Review on three axes

Invoke `/mattpocock-skills:code-review` for the standards and spec axes.

- **Standards** covers only what Credo and Dialyzer cannot: naming, the AGENTS.md rules, and the smell baseline. Do not have it re-check style that `mix precommit` enforces.
- **Spec** checks the diff against the ticket and the feature doc, including the bounds table and the research citations (see `docs/agents/review-checklist.md`, "Specs and bounds").

In the same message, spawn a third agent for the **failure-path axis**. It gets the diff and the checklist and nothing else: no review record, no summary of earlier fixes, no author notes, so it is not anchored on the author's view of the change. The brief:

> Read the diff and `docs/agents/review-checklist.md`. The checklist names categories; you enumerate the concrete cases. For every new or changed operation, state transition, and error branch, work through each category: input shape, the boundary at every named limit (at it, one under, one over, multibyte), resource bounds for every read, buffer, and wait, concurrency between sibling operations, and adversarial arguments from the model. Write throwaway tests as `.scratch/review/<name>_test.exs` at the repository root, run them with `mise exec -- mix test .scratch/review/<name>_test.exs`, and delete them when done. `.scratch/` is ignored by git; never put a throwaway test under `test/`. Report only findings you reproduced, each with the reproduction. Under 300 words.

A review agent that dies or stalls is rerun later. Never substitute the pass by hand.

Fix every confirmed finding. Record the findings and their resolution in `docs/reviews/YYYY-MM-DD-<scope>.md`.

If step 2 changed any code, run step 1 again on that change and then step 2 again on it. Review is always the last pass over the code.

## 3. Precommit

Run `mise exec -- mix precommit`. It must pass with no warnings.

## 4. Commit

Conventional commit, `type(scope): message`, with `Refs #<ticket>`. No attribution trailers of any kind.
