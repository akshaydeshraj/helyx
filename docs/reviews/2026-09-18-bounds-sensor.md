# Review: bounds sensor for /ship

Date: 2026-09-18. Branch: `process/bounds-sensor`. Scope: `.claude/skills/ship/bounds_sensor.py` and the ship skill paragraph that runs it. No ticket; the user asked for it in chat after the experiment below.

## What it is

A stdlib-only Python script. It sends each changed Elixir function to TypeSafe, a hosted classifier, with three closed questions: does the function take data whose size an outside party controls, what limits that data, and what ends a wait. It prints `SIZE` and `WAIT` flags at confidence 0.9 or more. The failure-path reviewer gets the flag lines as targets. A flag is a hint. No flag is not a pass. The script always exits 0.

The script sends source code to a service in the US that publishes no retention period. The user accepted that for this repository. The key comes from `TYPESAFE_API_KEY`. Without it the script prints a skip line.

## Experiment

Nine known bounds defects, each fixed in a later commit, asked at the commit before the fix.

| Threshold | Defects flagged | Flags on master at `93c33e9` | True flags |
|---|---|---|---|
| 0.9 | 6 of 9 | 12 | 9 |
| 0.7 | 8 of 9 | about twice as many | not counted |

- Every flag cleared at the commit that fixed its defect.
- The three false flags at 0.9 had their cap in a caller.
- One flag was a new real defect: `Helyx.SessionFile.resume/2` reads the whole file with no limit. It is issue #58.
- Answers near the threshold vary between runs: 12 or 13 flags on the same commit.
- The "limit" question alone flags almost everything. It needs the "growth" question as a filter.

Two ideas failed or were dropped:

- **Caller context.** A second version added the callers of each function to the state. It gave 21 flags against 12 and kept the false ones. Reverted. One function is the right state.
- **Allow-list for accepted flags.** Dropped. Diff mode only hints, so a false flag costs one line of reviewer attention.

## Rounds

Eight rounds. Rounds 1 to 5 and 7 were full rounds. Rounds 6 and 8 were spec plus failure-path, because the fix was small. Deviation from the skill: from round 2 on, the four simplify angles ran in fewer agents. Rounds 2 and 3 merged efficiency with altitude. Round 4 used two agents with two angles each. Round 5 used one agent for all four. Round 7 used one agent for the four angles and standards. Reviewers never got the real key; they used a stubbed `urlopen` or a bad key, each in its own directory under `.scratch/`.

| Round | Confirmed findings | Kind |
|---|---|---|
| 1 | IndexError on missing arguments; a git failure printed "0 functions"; wrong working directory; one API error discarded every answer; untracked files not scanned | false clean, crash |
| 2 | `defmacro` and 4-space defs not asked; a revision that starts with `-` reached git as an option and wrote a file; FIFO, symlink, and large file reads; check-then-open race | unsafe read, false clean |
| 3 | malformed answer shapes gave a clean result; `color.diff=always` gave "0 functions"; U+2028 shifted line numbers; unbounded response read; no size limit in `--commit`; a non-UTF-8 file ended the run; a symlinked parent directory led outside the repo | false clean, bounds |
| 4 | the size limit counted characters, so a multibyte file went out cut short with no line; a NUL byte made `git diff` print no hunks; text mode turned a lone CR into LF, which dropped a file and shifted lines; confidence outside 0 to 1 accepted; a docstring overclaimed | false clean, bounds |
| 5 | a name that cannot be encoded stopped every later result line; a newline in a name forged a line; `--commit` took a tree or a gitlink as a file | lost output, false clean |
| 6 | closed stdout exited 1; a newline in the revision forged a line through the failure message; a reader that left early exited 120 | exit status |
| 7 | a write error other than a closed pipe cut the output with no line | lost output |
| 8 | the same, for output under the 128 KiB stdout buffer | lost output |

The round 8 fix is one argument, `flush=True`. I checked it by hand against the reproduction and the three other stdout states and did not run another agent round on it.

## Mechanisms replaced

Two findings on one mechanism mean the mechanism is wrong. Three replacements came from that rule:

- **Answers.** A lenient read of the API answer became a strict check of every answer before use. Anything else is `NO ANSWER`.
- **Text.** Git output in text mode became bytes with one bounded decode point, `text()`. The size limit is on bytes.
- **Output.** Scattered `print` calls became one function, `say()`, that escapes to ASCII, flushes, stays silent when the reader left, and reports any other write error on stderr.

## Rejected findings

- `argparse`: it exits 2 on a usage error.
- SIGINT and SIGTERM handling: a user interrupt should stop the script.
- A hard link to a file outside the repo.
- A staged file that was deleted gives "0 functions". That is true.
- An `@doc` line maps to the clause before it. The cost is one extra question.
- A count check that answers equal candidates: `pool.map` makes that true by construction.
- A "files, functions, candidates" summary line. The skill already says that no flag is not a pass.
- A replaced `sys.stdout` object. It is not a shell state.
- Short-name nits and the `first == 0` sentinel for a whole-file failure.

## Known holes, stated in the code

- The real path check uses the path, and the open follows. A parent directory swapped for a symlink between the two gets through. It needs a hostile process in the user's own checkout.
- The request timeout is per socket operation, not a total deadline.
- A `def` line inside a heredoc becomes a clause.

## The sensor on its own diff

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

The diff has no file under a `lib/` directory, so this line says nothing about the script. Live check at `d99cbb5~1` on `plugins/provider_openai/lib/helyx/provider/openai.ex`: 22 candidate functions, 5 flagged, 0 without an answer, the same as before the eight rounds.

## Lesson for the process

Each round found real defects, and they moved outward: arguments, then the filesystem, then the API answer, then text encoding, then stdout. A script that crosses four OS boundaries took eight rounds. The state-table brief in the failure-path prompt found most of them. A review of the next script of this kind should start with that table for every boundary in round 1.
