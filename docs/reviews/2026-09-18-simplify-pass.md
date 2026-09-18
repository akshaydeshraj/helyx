# Review: simplify pass

Scope: `refactor/simplify-pass`. Three items accepted from an eleven-item simplify review of master: the root precommit alias finds its projects, `split_lines/1` in the OpenAI provider uses `List.pop_at/2`, and the docs and Credo paths follow.

## Change

- Root `mix.exs`: `aliases/0` lists `plugins/` and `apps/` and runs `mix precommit` in every directory that holds a `mix.exs`. A new plugin needs no line in the root file.
- `.credo.exs`: `apps/` is an included path.
- `AGENTS.md`: the Commands section describes the discovered list and says a project without a `precommit` alias fails the run.
- `plugins/provider_openai`: `split_lines/1` pops the partial last line with `List.pop_at(-1)` in place of two reversals.

## Withdrawn and rejected items

- **Delete `compaction_none`.** Withdrawn. Ticket #8 requires "The no-op Compaction plugin is registered and returns the context unchanged", and its review record already rejected the deletion. Reversing a ticket is the owner's decision, not a refactor.
- **Bash `os_pid` as a `with`.** Applied, then reverted. Standards and failure-path both reported that a `with` fall-through hides an unexpected `Port.info/2` value. The explicit `case` stays.
- **Delete `Message.Image`, move `Plugins` to `persistent_term`, delete `stream_data`, inline the Edit read and write wrappers, `declaration/1` tuple, delete the Twin test plugins.** Rejected. ADR 0001 names the image block, the Agent is not a measured cost, `stream_data` backs the property tests from #19, and the Twins are the duplicate-registration tests.

## Invariant

The root `mix precommit` runs `mix precommit` in every Mix project directly under `plugins/` and `apps/`, or fails loudly. It never passes while skipping one.

## Rounds

Each round ran four simplify agents, standards, spec, and failure-path. Failure-path got the diff and the checklist only.

1. Glob with a `File.exists?` filter and a sort. Simplify: glob `*/mix.exs` directly. Spec: the plugin deletion contradicts #8. Both applied.
2. Relative glob and an unquoted command string. Failure-path reproduced two silent skips: a directory name with a space, and `MIX_EXS` from another working directory, which gave an empty list. Fix: anchor to `__DIR__`, quote the path.
3. Spec and failure-path both reproduced two more on the same mechanism: glob characters in the checkout path (`repo[x]`) empty the list, and a paired quote in a name (`a""b`) runs `ab` twice. Dot directories were skipped as well. This was the third set of findings on one mechanism, so the patching stopped and the mechanism was replaced: `File.ls!/1` in place of a glob, and function aliases that pass an argument list to the `cmd` task in place of a command string. No parser remains on the path.
4. Review of the replacement. Six agents clean. Spec confirmed from the `cmd` task source and a scratch run that every call executes, because the task re-enables itself, and that a non-zero child stops the run with exit 1. Failure-path reproduced unbounded recursion: with `MIX_EXS` set, each child inherits it, loads the root project again, and starts its own children (91 nested processes in 25 s). The `__DIR__` anchor from round 2 made this state reachable. Fix: each function alias deletes `MIX_EXS` before it starts the child.
5. Review of that fix. Six agents clean; both projects ran once with the variable set, absolute and relative, and the child saw it unset. Failure-path findings rejected, see below. No code changed after this round.

## Rejected findings

- A symlinked plugin directory that also appears under its real name runs twice. Not a supported layout, and a second run is not a skip.
- A plugin directory with mode 600 is skipped, because `File.regular?/1` returns false on `eacces`. Git cannot produce that state, and an unreadable `plugins/` or `mix.exs` already fails loudly.
- `MIX_EXS` that names a symlink or copy of the root file in another directory, or another project, runs no sub-project. In that state Mix has loaded a different project root, so format, compile, Credo, Dialyzer, and test also run on the wrong tree. The root file cannot govern a run that does not start from it.
- Standards judgement calls left as they are: rename `root`, shorten the history in the comment, say why the `delete_env` call sits inside the closure.
- A project nested below `plugins/<group>/` is not found. The documented layout has one level.

## Failure path

Reproduced against the final form in a scratch repo at a path with `[x] {a,b}` and a space, with projects named `ab`, `a""b`, `.hid`, `zz space`, ``$x`y``, and `-dash`: all six ran. With `MIX_EXS` set, two projects ran once each and the run ended. A project without a `precommit` alias exits 1.
