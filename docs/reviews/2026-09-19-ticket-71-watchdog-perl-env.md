# Review: ticket #71, perl environment variables and the bash watchdog

Date: 2026-09-19. Branch `ticket/71-watchdog-perl-env`. Base `d785796` (`origin/master` at the start of the work). Master moved to `4fd5d38` during round 3 (#67 and #74, no bash tool change); rounds 1 and 2 used `git diff origin/master`, round 3 used `git diff HEAD`, which is the same diff.

## The change

`launcher/3` now returns the full option list of the port. The `:env` option removes every variable whose name starts with `PERL`, except `PERL_BADLANG`, and adds each value again under the name `HELYX_KEEP_<name>` with a `=` in front of the value. The watchdog gives each `HELYX_KEEP_PERL*` variable its name back in `%ENV` before the fork. The `binmode` of the report pipe and the `utf8::encode` of the reason (#70) are deleted: the #70 tests for `PERL_UNICODE=A` and for a bash path with characters of two and three bytes pass without them.

Invariant: no `PERL*` variable of the environment changes how the watchdog runs, and the command gets the user's environment. Documented exceptions: (1) `PERL_BADLANG` stays in the watchdog's environment, because it only stops the locale warning; (2) the prefix `HELYX_KEEP_PERL` is reserved, and a user variable with it reaches the command without `HELYX_KEEP_` and without the first character of its value; (3) a `PERL*` name or value that is not UTF-8 is decoded as Latin-1 by the VM: the value reaches the command with other bytes, and the name is not removed (open, ticket pending); (4) a program `perl` first in `PATH` that is not perl, and a command that attacks its own watchdog on purpose, are out of scope.

## Bounds sensor

Every round printed the same line:

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1 (full, first round)

The first form of the fix sent the values as `NAME=value` arguments after the command.

Simplify, 4 agents.

- Reuse: 2 findings. Applied: the fake `perl` and the bad `bash` of the tests use one helper, `put_first_in_path/3`. Not applied: a shared `open` helper in `OSHelpers` for two call sites.
- Simplification: 3 findings, all applied. The helper above; one name for each list in `launcher/3`; the change of `sysread(...) == 0` to `!sysread(...)` had no effect (`undef == 0` is true in perl), so the old line is back with a comment that gives the reason.
- Efficiency: 2 findings, applied. The `PERL_UNICODE` test has the five values of the ticket and no more.
- Altitude: 1 finding, applied. Arguments are in the process table for all users. The values now stay in the environment under `HELYX_KEEP_<name>`, which only the same user can read. The argument list of the watchdog is as before #71. A value over stdin was rejected: stdin already carries the go-ahead and the end-of-file signal.

One defect came from the simplify change and was found by the new test before the review: the port takes an empty `:env` value for "remove", so an empty `PERL*` value was lost. An empty `PERL_UNICODE` is not the same as none (`${^UNICODE}` is 95, not 0). Fix: the `=` in front of each kept value.

Review:

- Standards: 2 hard findings, docs. The `ponytail:` marker and the "no size limit" sentence named no ticket. The marker and the row now say `ticket pending`, and the row states the OS limit as the bound. 6 judgement calls. Applied: `substr($_, 11)` is gone (the regex captures the name), the comment wrap, the test title. Not applied: see "Judgement calls not applied".
- Spec: 1 defect, reproduced. The restore loop matched every `HELYX_KEEP_*` name, so `HELYX_KEEP_HOME=/nowhere` replaced `HOME` for the command. 2 partial items: the `PERL5OPT=-d` test did not check "no process behind" (now it does, through a stand-in for the hands), and no test makes a read of the port fail (see "Acceptance criterion 3").
- Failure path: 2 findings, both reproduced. (1) The same defect, with `HELYX_KEEP_PATH`. (2) A `PERL*` name that is not UTF-8 is not removed, and the command gets a second variable with the decoded name. perl reads no such name. The row and the `ponytail:` marker now state it, ticket pending.

Fix for the defect: the loop matches `/^HELYX_KEEP_(PERL.*)/s` only. Test: `only the reserved prefix HELYX_KEEP_PERL is taken`; it fails with the wide regex. The fix is 1 watchdog line and comment lines in one file, with no function changed: a reduced round.

## Round 2 (reduced: spec and failure path)

Invariant named in both briefs, as above.

- Spec: 0 defects. 12 shapes of names and values held (the name `PERL`, a value `=x`, an empty value, a user `HELYX_KEEP_PERL_Z` together with `PERL_Z`, names with a line break, names and values that are not UTF-8). No false sentence in the rows.
- Failure path: 1 finding, reproduced. `PERL_BADLANG=0` no longer reached the watchdog. With a locale that the system does not have, perl's warning came back in front of every result, and a warning over the preamble limit stopped every command.

Fix: `PERL_BADLANG` is not removed. It is 3 lines in one file. This is the second finding on "which names move", so the two-findings rule makes the next round a full round, and its altitude pass judged the mechanism.

## Round 3 (full)

Simplify, 2 agents with two angles each (a deviation from the four-agent form, as in the #70 record).

- Reuse and efficiency: 3 small findings. Applied: `group_gone_within?/2` for the watchdog. Not applied: a shared stand-in for the hands in `OSHelpers` (the one in `bash_test.exs` does a different thing), and one `Enum.flat_map` in place of two comprehensions (readability only).
- Simplification and altitude: the prefix rule is the right base; a fixed list of names goes stale and a missed name breaks the watchdog. The agent proposed `PERL_BADLANG=0` for the watchdog always, in place of the exception. Not applied: it removes perl's locale warning for every user, which is a change of behaviour outside the ticket, and the five tests of `bash_preamble_test.exs` that use the warning as preamble text would lose their source. The report names it as an option. Applied: the sentence "the watchdog is the same program in every environment" was false and is now "no `PERL*` variable except `PERL_BADLANG` changes how the watchdog runs".

Review:

- Standards: 0 hard findings, 5 judgement calls. Applied: the test for the reserved prefix now also covers the documented cost (`HELYX_KEEP_PERL_HELYX_C=abc` gives `PERL_HELYX_C=bc`), and the comment block is wrapped again. Not applied: see below.
- Spec: 0 defects. 10 more `PERL*` variables (`PERLIO`, `PERL_HASH_SEED_DEBUG`, `PERL_SIGNALS`, `PERL5DB`, `PERL_MEM_LOG`, `PERLLIB`, `PERL_ENCODING`, `PERL_DESTRUCT_LEVEL`, `PERL5OPT="-Mstrict -w -T"`, the name `PERL`): every result ok, no perl text, the command saw the value. 7 values of `PERL_BADLANG`, 100,000 digits included: no harm to the watchdog. 1 sentence too broad, corrected (above). 1 note by reasoning, now in the row: a perl that finds POSIX only through `PERL5LIB` cannot run the watchdog.
- Failure path: 0 findings. The round 2 reproduction passes. One note, now in the row: each variable adds 12 bytes, so an environment within those bytes of the OS limit now fails; not reproduced.

The changes after this review are comments, tests, and Markdown. No further round.

## Acceptance criterion 3

"Any failed read of the port in the watchdog kills the group." The poll is `sysread(STDIN, ...) == 0`. A read that fails gives `undef`, and `undef == 0` is true in perl, so a read error takes the kill branch. A `readline` that gives `undef` before the go-ahead takes its kill branch too. The one fatal read was the `:utf8` layer of `PERL_UNICODE`, which cannot reach the watchdog now. No test makes a read of the port fail: the port gives no way to do it. The comment above the watchdog states the rule.

## Judgement calls not applied

- `launcher/3` keeps its name. It returns what the port needs to launch the watchdog.
- `List.replace_at(args, 5, bash)` in `watchdog_test.exs` is older than this change, and the argument order did not change.
- The `start_report/4` rule "the report counts wherever it is in the output" stays. #71 removed its one known source of text (`PERL5OPT=-w`), so no test reaches it now. It fails to the safe side, and the bounds row says so.
- Passive voice in the bounds rows follows the rows around them.

## Outside the ticket

- Ticket pending: a `PERL*` name or value that is not UTF-8 (exception 3 above). Before #71 these bytes reached the command as they were.
- Ticket pending: the marker read has no time limit. With a real perl it ends. A program `perl` first in `PATH` that writes nothing and never exits holds the call until the turn abort. This is older than #71.
- The first run of the test for kept values printed the whole environment of the machine in a failed assertion. The test now prints only its own variables, and every review brief forbids a print of the whole environment. The environment of this machine holds two tokens; they went to the local session transcript only.
- The red run of the `PERL5OPT=-d` test left two processes of the defect (a watchdog in the debugger and its child). They were killed by pid. Four older watchdogs of another worktree (55586, 55589, 56296, 56306) were not touched.

## Precommit

Passed on the final code, on base `d785796`: root 1 property and 127 tests, `plugins/bundled` 175 tests, `apps/coding_agent` 5 tests, 0 failures. The two `[error] GenServer ... killed` lines in the log of `plugins/bundled` are the log of the tests that kill the hands.
