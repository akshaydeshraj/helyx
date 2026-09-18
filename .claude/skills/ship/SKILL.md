---
name: ship
description: The only way to commit in this repo. Simplify, review on three axes, run precommit, then commit.
---

# Ship

Every commit goes through this skill. Run the steps in order. The only exemption: a change that touches nothing but Markdown skips steps 1 and 2. There is no diff-size exemption and no reviewed-by-hand path; a one-line code fix gets the same first round as a feature. Only a rerun round after a review fix is smaller, see step 2.

## 1. Simplify

Invoke `/simplify` on the working tree changes. Apply its fixes. Simplify is bug-blind by design, so anything it touches is reviewed again in step 2.

## 2. Review on three axes

Invoke `/mattpocock-skills:code-review` for the standards and spec axes.

- **Standards** covers only what Credo and Dialyzer cannot: naming, the AGENTS.md rules, and the smell baseline. Do not have it re-check style that `mix precommit` enforces.
- **Spec** checks the diff against the ticket and the feature doc, including the bounds table and the research citations (see `docs/agents/review-checklist.md`, "Specs and bounds").

In the same message, spawn a third agent for the **failure-path axis**. It gets the diff and the checklist and nothing else: no review record, no summary of earlier fixes, no author notes, so it is not anchored on the author's view of the change. The brief:

> Read the diff and `docs/agents/review-checklist.md`. The checklist names categories; you enumerate the concrete cases. For every new or changed operation, state transition, and error branch, work through each category: input shape, the boundary at every named limit (at it, one under, one over, multibyte), resource bounds for every read, buffer, and wait, concurrency between sibling operations, and adversarial arguments from the model. For code that crosses to the OS, the filesystem, or the network, build a state table: list the external states (not started, running, exited with the port open, exited with the port closed, stuck) and cross them with the BEAM events (spawn, register, abort, Task kill, delivery). Test the cells; suspending a Task with `:erlang.suspend_process/1` to hold a window open is a named technique. Write throwaway tests as `.scratch/review/<name>_test.exs` at the repository root, run them with `mise exec -- mix test .scratch/review/<name>_test.exs`, and delete them when done. `.scratch/` is ignored by git; never put a throwaway test under `test/`. Report only findings you reproduced, each with the reproduction. Under 300 words.

A review agent that dies or stalls is rerun. Never substitute any pass by hand, whatever the diff size.

Fix every confirmed finding. Record the findings and their resolution in `docs/reviews/YYYY-MM-DD-<scope>.md`.

If step 2 changed any code, review that change again. Review is always the last pass over the code. A rerun round is smaller than the first round:

- **Reduced round:** the spec and failure-path agents only. They found every real bug in the rerun rounds of PR #30; the simplify and standards agents found none.
- **Full round:** step 1, then all of step 2.

Count the fix from its diff, without test files and Markdown. The rerun is a full round when any one of these is true:

- it changes more than 15 lines, added plus removed
- it touches more than one code file
- it adds or removes a function, a module, a process, or a dependency
- it changes the arity, the return shape, or the spec of a function
- the two-findings rule below applies to it

Otherwise the rerun is a reduced round. If a line of this list is in doubt, the answer is a full round. The review record states the counts and the round type for each rerun.

The first round is always complete. No round is ever done by hand.

Two more rules govern the loop:

- **Fix reviews target the invariant, not the reproduction.** When the change fixes a review finding, every review brief names the invariant the fix restores and asks the agents to find another path that breaks the same invariant. The finding's reproduction is the first test the agents run, not the last.
- **Two findings on one mechanism stop the patching.** When a second finding lands on a mechanism a previous round already patched, the next round fixes the mechanism, not the path. See `docs/agents/review-checklist.md`, "Races and resource ownership".

## 3. Precommit

Run `mise exec -- mix precommit > precommit.log 2>&1; echo $?`, and search the log as `AGENTS.md` says. It must pass with no warnings. Never pipe it to `tail`, and never rerun it to read an error.

## 4. Commit

Conventional commit, `type(scope): message`, with `Refs #<ticket>`. No attribution trailers of any kind.
