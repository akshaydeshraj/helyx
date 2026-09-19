# 2026-09-19: the bash watchdog runs without the perl variables (issue #71)

## Done

- The port starts the watchdog without every variable whose name starts
  with `PERL`, except `PERL_BADLANG`. Each value stays in the environment
  as `HELYX_KEEP_<name>`, and the watchdog gives it its name back in
  `%ENV` before the fork. The command sees the user's values.
- One fix closes all paths of the ticket: `PERL_UNICODE=I` and `i` (the
  closed port did not kill the group), `o` and `D` (no start line), `A`
  (the lost reason of a failed `chdir`), and `PERL5OPT=-d` (the marker
  read with no end).
- The `binmode` of the report pipe and the `utf8::encode` of the reason,
  from #70, are deleted. The #70 tests pass without them.
- `launcher/3` returns the option list of the port, so the direct tests
  of the watchdog get the same environment as the tool.

## What broke

- The port takes an empty `:env` value for "remove". An empty
  `PERL_UNICODE` is not the same as none, so each kept value has a `=` in
  front.
- The first restore loop took every `HELYX_KEEP_*` name and could replace
  `HOME`. It now takes `HELYX_KEEP_PERL*` only.
- The removal of `PERL_BADLANG=0` brought perl's locale warning back.
  `PERL_BADLANG` now stays.
- A failed assertion printed the whole environment. The test now prints
  only its own variables.

## Next

- Ticket pending: `PERL*` names and values that are not UTF-8.
- Ticket pending: a time limit for the marker read (a `perl` in `PATH`
  that is not perl).
- Option, not taken: `PERL_BADLANG=0` for the watchdog always. It removes
  the locale warning for every user and the text source of five tests.

Review record: `docs/reviews/2026-09-19-ticket-71-watchdog-perl-env.md`.
