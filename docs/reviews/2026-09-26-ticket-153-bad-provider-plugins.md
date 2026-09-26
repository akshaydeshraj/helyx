# Review: bad provider plugins, `id/0` and `bad_provider_turn` text (#153, #158)

Date: 2026-09-26. Base: `origin/master` at d7ca9fc. Ticket #153, with #158 folded in by the owner.

## Invariant

A provider plugin's `id/0` that raises, throws, exits, or returns a value that is not a binary never crashes the caller of `Helyx.Session.start/2`, `resume/2`, or `set_model/2`. `Helyx.Provider.find/2` contains it and returns `{:error, {:bad_provider_id, module}}` for any valid ref. The specs of the three entry points list it through `t:Helyx.Session.model_error/0`. The spec of `set_model/2` is the boundary of the TUI `model_error/1`, which has one clause for each error and no catch-all. `CodingAgent.error_text/1` has a sentence for `{:bad_provider_turn, id}` and `{:bad_provider_id, module}`. The text that shows the module is at most 2,043 bytes, and the "Provider id" row of `docs/features/coding-agent.md` states that bound and every effect of `id/0` and `turn/0` that is not contained.

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify (4 agents): reuse 0, simplification 2, efficiency 0, altitude 1.

- Skipped: one pass that collects only matches, and a bare id in place of `{:ok, id}`. The current form follows `Helyx.Tool.specs/1`.
- Skipped: a check of `id/0` at Core boot. The ticket names `find/2`, and `turn/0` follows the same runtime pattern. Reported to the orchestrator as a possible follow-up.

Standards: 0 hard findings, 6 judgement calls.

- Fixed: the name `ids/1` became `plugin_ids/1`; the `find/2` `@doc` wording; the long error sentence of the model switching paragraph became a list.
- Not fixed: the shared shape of `id/1` and `turn/1` (two cases), the two copies of the test provider (the Mix projects cannot share test support), and the error wording that each client keeps (this was there before).

Spec: 2 findings, 1 note.

- Fixed: the specs of `start/2` and `resume/2` did not list the new error. `@type model_error` now holds the five errors, and the three specs use it.
- Fixed: the bounds table had no row for the module text. A "Provider id" row now states it. The worst case of `inspect/1` on an atom is 8 bytes for each character (`\x{FFFE}`), measured over all code points, so 255 characters give 2,043 bytes.
- Note: a value of `id/0` that is not a binary is also an error. This follows the boundary rule and `turn/1`.

Failure-path: 0 findings. Probes of `exit(:kill)`, `:erlang.error/1`, and ids that are empty or not UTF-8 all gave the tagged error or could not match a ref.

## Round 2 (full)

The fix touches three code files and changes specs.

Simplify: 4 small findings. Fixed: the private `id/1` became `checked_id/1`, and the TUI comment points to the bounds row. Skipped: `model_error() | term()` in the specs of `start/2` and `resume/2`, because the ticket asks that these specs list the error.

Standards: 0 hard findings. Fixed: the `set_model/2` `@doc` points to `t:model_error/0`; "Two matches are an error"; the `@typedoc` wording.

Spec: 1 finding. Fixed: the Model ref row and the TUI comment said that a notice shows at most the provider id.

Failure-path: 2 doc findings, reproduced. Fixed: the Provider id row now states that an exit signal to the caller is not contained and that `id/0` has no deadline.

## Round 3 (full)

The fix touches three code files (doc strings and a comment only).

Simplify: 2 findings (repeated text), skipped: without that text the general claim "at most the provider id" is false.

Standards: 1 judgement call. Fixed: the Provider id row named `turn/0` as the precedent for no deadline, but only a tool `check/0` records that.

Spec: 2 findings. Fixed: the "session client calls" row now says that `set_model/2` runs `id/0` and `turn/0` in the caller before its call. Not fixed: `Helyx.Core.plugins/2` is an `Agent.get` with the default timeout of 5,000 ms, and no row states it. This was there before; reported.

Failure-path: 0 findings.

Precommit failed on Credo strict: `find/2` nested to depth 3.

## Round 4 (full)

The fix adds the private `match/2`, which holds the three-way match of `find/2`.

Simplify: 0 fixes (one optional style change skipped). Standards: 0 hard findings (the name `match/2` is a judgement call, kept). Spec: 2 findings, fixed in the row: `turn/0` also has no deadline, and for `/model` the blocked caller is the TUI process. Failure-path: 0 findings, 1 note, fixed: the row said "A string" but the check is `is_binary/1`.

## Round 5 (reduced)

The fix is Markdown only.

Spec: 3 findings, fixed: the `find/2` `@doc` said "not a string"; the row said "for any ref", but an invalid ref runs no `id/0`; the row did not say that a resume can repair the file before the error (accepted in #104).

Failure-path: 1 finding, reproduced: an `id/0` that leaves a monitor message in the TUI mailbox makes the TUI stop on the next `:DOWN`. Fixed in the row as an accepted effect. The TUI `:DOWN` clause that matches any monitor was there before; reported.

## Round 6 (reduced)

The fix changes one `@doc` line in one code file and Markdown.

Spec: 0 findings. Failure-path: 1 finding, reproduced: `id/0` can set `trap_exit`, write the process dictionary, or take a message from the caller's mailbox. This is the second finding on one mechanism, plugin code that runs in the caller, so the next fix states the class, not the case.

## Round 7 (reduced)

The fix is Markdown only: the row accepts every change to the process state of the caller.

Spec: 1 finding: effects on other processes or the node, such as an `id/0` that stops the session, so the later `GenServer.call` of `set_model/2` exits. Failure-path: 0 findings.

Fixed at the mechanism: the row now says that the checks cover only a raise, a throw, an exit, and the return value, and that every other effect of `id/0` and `turn/0` is accepted, also one that makes a later step of the same call exit.

## Round 8 (reduced)

The fix is Markdown only. Spec: 0 findings. Failure-path: 0 findings.

## Precommit

`mix precommit` passed in the root, `plugins/bundled`, and `apps/coding_agent`.

## Out of scope, reported

- A check of `id/0` (and of a shared id) at Core boot, so that a bad plugin fails early.
- `Helyx.Core.plugins/2` waits up to 5,000 ms, and no row states it.
- The TUI `:DOWN` clause matches any monitor, not only the monitor of the session.
- The tool rows accept an exit signal and a missing deadline, but not the other effects of plugin code on the caller that the Provider id row now states.

## Orchestrator

- Codex adversarial review, round 1: no finding. The base did not change after the precommit run of the worker.
- Accepted: one bad `id/0` fails every lookup (a unique match cannot be proven without it); a non-binary `id/0` is a bad id (boundary rule); the start and resume specs name `model_error()`.
- Follow-ups: the check of `id/0` and of shared ids at Core boot goes to #165, which already changes the plugin table and removes the 5,000 ms wait of `Helyx.Core.plugins/2`. The TUI `:DOWN` clause is filed separately.
