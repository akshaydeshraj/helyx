---
name: ship
description: The only way to commit in this repo. Simplify, review on three axes, run precommit, then commit.
---

# Ship

Every commit goes through this skill. Run the steps in order. Do not skip a step because the diff is small. A change that touches only Markdown skips steps 1 and 2.

## 1. Simplify

Invoke `/simplify` on the working tree changes. Apply its fixes. Simplify is bug-blind by design, so anything it touches is reviewed again in step 2.

## 2. Review on three axes

Invoke `/mattpocock-skills:code-review` for the standards and spec axes. In the same message, spawn a third agent for the **failure-path axis** with this brief:

> Read the diff and `docs/agents/review-checklist.md`. List every new or changed state transition, error branch, and input shape. For each one, try to break it: empty input, wrong shape, extra tuple element, duplicate configuration, a crash mid-stream, a module that does not exist, a failure after partial output. Write throwaway tests in the scratchpad directory and run them with `mise exec -- mix test <path>`. Report only findings you reproduced, each with the reproduction. Under 300 words.

Fix every confirmed finding. Record the findings and their resolution in `docs/reviews/YYYY-MM-DD-<scope>.md`.

If step 2 changed any code, run step 1 again on that change and then step 2 again on it. Review is always the last pass over the code.

## 3. Precommit

Run `mise exec -- mix precommit`. It must pass with no warnings.

## 4. Commit

Conventional commit, `type(scope): message`, with `Refs #<ticket>`. No attribution trailers of any kind.
