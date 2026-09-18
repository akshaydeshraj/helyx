# 2026-09-18: One owner for the lifetime of a command (#37)

## What was done

Replaced the four partial cleanup mechanisms with two rules (issue #37, ADR 0004 revised):

- Inside the VM, work is linked to its owner. The provider Task links to the session, the tool Task links to the hands, and both owners trap exits. A death anywhere above, even `Process.exit(pid, :kill)`, takes everything below it. `terminate/2` covers the one case links do not: a holder that exits with reason `:normal` while work runs.
- At the OS boundary, the perl launcher became a watchdog. It forks the command into its own process group, writes the group marker, holds the command until the go-ahead, and then watches its stdin. A closed port, from any death above, TERMs the group, waits 500 ms, KILLs it, and reaps the command. When the command ends first, the watchdog passes the exit status through, `128 + signal` for a signal death.

The hands now hold groups as a set per Task (a second registration adds), wait on real elapsed time, and remember a group that survives KILL as stuck: the result is an error, `cancel/2` reports the failure, and later tool calls are refused with an error result while the group lives. Tools got an optional `check/0` that runs when the hands start; bash uses it to require perl.

Deleted: the port scan by Task pid, the perl-less launcher mode and the best-effort os pid lookup, and the rule that killed a late registration.

## What broke

- The strict abort test saw the shell as alive after cancel: the shell is a zombie until the watchdog reaps it, and `kill -0` counts a zombie. Fix: the bash tool also registers the watchdog's own group (the port's OS pid; the runtime detaches port programs), the watchdog ignores TERM in the parent only and always reaps before exit, so the hands' wait cannot end before the command is reaped.
- A port closed before the child's `setpgrp` made the group KILL miss and the watchdog deadlock in `waitpid` while holding the pipe the child was reading. Fix: close the write end first in that branch.
- Stopping Core mid-test killed the test process: the events Registry links its subscribers, so the test traps exits.

## What is next

- Flow control for bash output that queues in the Task mailbox (#36).
- Zombie counting in containers without a reaper (#25).
