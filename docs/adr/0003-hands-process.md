# Tools run in a hands process, not in the session

Every session has a hands process that owns the working directory and runs tool calls. The session addresses it by pid. In local mode the hands live on the same node. The reason is distribution: a later product will run the session on one machine and the hands on another, such as a Docker container or a machine with a browser. Making that boundary a process from the first commit keeps tool calls and results as plain terms and keeps the tool set owned by the hands, so moving the hands to another node changes nothing in the session.

## Considered options

- Call tools as local functions inside the session process. Rejected: the boundary would have to be added later, and by then tool calls and results would carry pids and closures.

## Consequences

- Tool calls and results contain no pids, functions, or references.
- The set of available tools is reported by the hands, not configured on the session.
- Harness providers are also spawned on the hands side, because they are shell processes that act on the working directory.
