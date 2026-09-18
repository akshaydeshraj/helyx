# Review: precommit fetches its own dependencies

Scope: `build/precommit-deps-get`. No ticket. The cause was the worktree run of #34: after a rebase brought new projects, the agent fetched dependencies by hand, missed `apps/*`, piped precommit to `tail`, and ran precommit about six times to read one error.

## Change

- All eleven `mix.exs` files: the `precommit` alias starts with `deps.get --check-locked`.
- Root `mix.exs`: the alias prints `==> precommit <project>` before each child run. The comments sit next to the code they explain.
- `AGENTS.md`: precommit output goes to `precommit.log`, with a grep line to search it. Never pipe to `tail`, never rerun to read an error. After a dependency change, one loop updates every lock.
- `.claude/skills/ship/SKILL.md`: step 3 uses the log.
- `.gitignore`: `precommit.log`.

## Invariant

`mix precommit` needs no manual fetch in a fresh worktree or after a rebase that adds a project. It never changes a lock file. A failure names its project in the log.

## Rounds

Failure-path got the diff and the checklist only in every round.

### Round 1, full: 4 simplify, standards, spec, failure-path

- Reuse, simplification, efficiency: clean. The fetch costs about 2 s per project when nothing is missing.
- **Failure-path, fixed:** plain `deps.get` wrote a new entry into `mix.lock` with exit 0, so precommit changed a tracked file without a word. Now `--check-locked` fails the run with "Your mix.lock is out of date".
- **Spec and altitude, fixed:** a failed fetch in a child did not name the child. The root now prints a banner before each child.
- **Standards, fixed:** `precommit.log` was not ignored, AGENTS.md had no search command, and the ship skill still ran precommit without a log.
- **Standards, accepted as is:** the same alias list in ten child projects. The root list differs, and a shared file would be a new mechanism for five strings. Ticket #38 reduces the count.

### Round 2, full: the fix touched more than one code file

- Reuse, efficiency: clean. The `cmd` task prints no directory, so the banner is not redundant. `--check-locked` adds no work when the lock is current.
- Spec reran both round 1 reproductions in a scratch project: both now fail or name the child as intended. Missing `deps/` with a current lock is still fetched.
- **Simplification, fixed:** the ten-line comment block at the top of `aliases/0` held three topics. Each topic moved next to its code.
- **Failure-path, fixed:** the comment said a stale lock fails the run. A lock entry that no `mix.exs` uses passes. The comment now names the two cases that fail.
- **Failure-path and altitude, fixed:** a root dependency change makes every child lock stale, and AGENTS.md said to fetch "in that project". AGENTS.md now gives a loop.
- **Standards, fixed:** an error above the first banner belongs to the root; AGENTS.md says so. The banner comment named only a failed fetch.
- **Standards, rejected:** the ship skill says `mise exec -- mix`, AGENTS.md says `mix`. AGENTS.md uses plain `mix` in every command; the skill adds the local toolchain wrapper.
- **Failure-path, rejected:** add `deps.unlock --check-unused`. An unused lock entry breaks no invariant here.

Cells that held: no `mix.lock` with a Hex dependency fails and writes no file; conflict markers fail under the banner; no network with a warm Hex cache passes.

### Round 3, rerun: spec and failure-path, the fix changed comments in one code file

- **Spec, fixed:** a plugin change also makes the `apps/coding_agent` lock stale, and `provider_fake` is a test dependency of six plugins. The AGENTS.md sentence now covers every path dependency, and the loop includes the root.
- **Failure-path, fixed:** the loop variable is quoted.
- **Failure-path, rejected:** an empty `apps/` directory stops the loop in zsh, and a non-project directory under `plugins/` prints an error. Git tracks no empty directory, and the root alias already skips non-projects; the loop is a recovery aid, not a gate.

The last fix changed Markdown only. I ran the loop as written: eleven projects, every exit 0, no lock changed.

## Proof

- Main checkout: `mix precommit > precommit.log` exit 0, eleven Dialyzer runs clean, eleven test runs with 0 failures, ten banners.
- Fresh worktree at `origin/master` with the round 1 diff and zero `deps/` directories: exit 0 with no manual fetch, eleven test runs with 0 failures, no lock file changed. It used about five minutes of CPU, most of it eleven new Dialyzer PLTs. The wall time is not usable: other precommit runs shared the machine.

## After the PR: Greptile

- **Fixed:** the documented command ended in `; echo $?`, so the whole command exited 0 after a failed precommit. It now ends in `&& echo passed || { echo failed; false; }`, which prints the result and keeps a non-zero status. Tested in zsh and bash with a failing and a passing command. Markdown only, so no review round; precommit passed when run with the new command.
