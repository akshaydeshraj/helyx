# 2026-09-19: the bash tool knows that the command started (issue #70)

## Done

- The watchdog has a report pipe that closes on `exec`. The held child
  writes the start line `<nonce> 1` before the `exec`, and it writes the
  reason to the report pipe when the `exec` fails or the child ends by `die`.
- The watchdog reads the report pipe after the child ended and writes the
  failure report, `<go> 0` and the reason. `<go>` is a second random word,
  sent as the go-ahead line, so a command cannot forge a report.
- `start_report/4` makes the result: no start line, or a failure report,
  is `{:error, "the command did not start: ..."}`.
- Tests: a bash that cannot be executed, the same with `PERL5OPT=-w`,
  `PERL_UNICODE=i`, a watchdog killed before the go-ahead, real exit
  statuses 127, 137, and 255, a failed `exec` on the port, and a stopped
  child with a closed port.
- The bounds row "bash command start after the group marker" is closed, and
  the ownership table has a row for the report pipe.
- Review record: `docs/reviews/2026-09-19-ticket-70-start-report.md`.

## What broke

- The first version matched the failure report only at the start of the
  output. With `PERL5OPT=-w` a perl warning came first and the result was ok.
  The report now counts wherever it is.
- The first version read the report pipe with a blocking read before the
  poll loop. A stopped child held the watchdog, and a closed port did not
  kill the group. The read now happens after the child ended.
- `origin/master` moved during the work (#68). The branch was fast-forwarded
  before precommit.

## Next

- #71: `PERL_UNICODE=I` breaks the watchdog's read of stdin. `binmode` on the
  go-ahead pipe also makes `PERL_UNICODE=i` run the command.
- Ticket pending: `PERL5OPT=-d` makes the marker read wait without a limit.
