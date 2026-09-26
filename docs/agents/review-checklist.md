# Review checklist

Invariants the review axes check on every diff. Add one when a review or a PR comment finds a defect that a checklist line would have caught. The failure-path brief in the ship skill names the probe categories; the lines here are the invariants the probes must not break.

## Specs and bounds

- The feature doc states the bound of every input, buffer, and wait, or says "unbounded, ticket #N". The spec axis checks that table against the diff.
- Any numeric limit in code has a property test or, at minimum, tests at the limit, one under, one over, and a multibyte case.
- Every `ponytail:` marker names a ticket. Judge whether the debt is safe to ship, not only whether it is recorded.
- A design decision that the tools research (`docs/research/coding-tools.md`, issue #17) covered cites it in the feature doc, so the spec axis can check the design against how codex, opencode, and pi behave.
- Every external resource in the diff (OS process, process group, port, file handle, socket, temp file) has a row in the feature doc's ownership table. A row whose release path dies with its owner is a design flag the spec axis raises (ADR 0004).

## Boundaries

- Each input is checked at its boundary (see `AGENTS.md`, "Elixir guidelines"). The spec axis names the boundary of every new input.
- Inner code has no defensive handling: no fallback clause, `{:error, _}` return, `rescue`, or repair for a state that no caller can make. A reviewer reports such code as a finding, with every caller and the upstream check (`file:line`). A repeated check is a finding only when the earlier check still proves the same property; a documented safety check and a check of a limit that a transformation, an accumulation, or elapsed time introduces are not findings.
- Later code uses the checked value. A new read of the source is a finding only when its value is used under the earlier check with no check of its own.
- A boundary check rejects the smallest unit that permits safe continuation. The failure path names what one bad value destroys, and the feature doc states each case where missing identity, damaged structure, or an unresolved resource requires a larger failure.
- A public plugin entry (a tool's `run/2`, a provider's `stream/3`) is a boundary for all of its arguments, because code outside the hands and the session can call it.
- A finding needs a reachable input: its reproduction enters through a boundary. Source: the boundary review of 2026-09-26.

## Races and resource ownership

- A race is closed structurally or stated as a hole. It is never accepted by window size or by who the caller is today. An open race is written in the ownership table as "open, ticket #N", the same vocabulary as an unbounded input.
- Two findings on one mechanism stop the patching. The next round fixes the mechanism, not the path.
- A `receive` loop with a deadline checks the deadline before each `receive`. A matching message in the mailbox wins over `after`, even with a timeout of 0, so a sender that never stops keeps the loop past its deadline. The failure path queues messages past the deadline and checks that the loop acts on it. Source: the Codex round 1 finding of #11.
- Every resource has a release path that works when its owner dies (ADR 0004): inside the VM through links to the owner, at the OS boundary through the port watchdog. The resource is still held with the hands, with `Helyx.Tool.hold/1`, before the external work starts, because delivery and cancel wait until it is gone.

## Events

- Every `message_start` gets a `message_end` on the same turn, on success and on failure.
- Every turn ends with `agent_end`, on success and on failure.
- Sequence numbers increase by one per event within a session, with no gaps.

## Sessions and turns

- A failure in a turn never crashes the session. The turn fails, the session accepts the next prompt.
- A message from a Task that is no longer current never touches the session.
- A stream that ends without a terminal event fails the turn.
- A partial assistant message from a failed turn is not added to the transcript.
- An id of outside state (a harness session, a remote job) is reused only when that state has received everything it needs, for example the whole replay. The failure path builds the table of the id's life (stored, first use, completed) crossed with abort, steer, failure, a Task crash, and a restart, and tests each cell. Source: the Codex round 1 finding of #10.

## Plugins and Core

- Bad configuration returns `{:error, reason}` from `start_link`; it never raises. This includes a module that does not exist, two plugins for a single-mode interface, no plugin for a required one, and two providers with one id.
- Core knows no interface by name except the fixed list it checks at boot.

## Inputs from plugins

- A value from a plugin is checked by shape before it reaches a process that holds state. Match the whole tuple or struct, never elements by index.
- Providers are compiled into the node. Shape is checked; individual field values are not.
- A plugin callback that runs in the caller of a session start or resume (a tool spec callback, `turn/0`), and any plugin code that the check of its value runs (a JSON encoder of a plugin struct), has its raise, throw, and exit contained and returned as `{:error, reason}`. Open: `id/0` in `Helyx.Provider.find/2` is not contained yet (#153). Source: the Codex round 1 finding of #142.

## Tools and hands

- A tool Task that dies without a result still produces a tool result, with `is_error` true.
- The tool calls of one assistant message run one at a time, in call order, so no two touch the working directory at once.
- Truncation holds for trailing blank lines, for a line exactly at the byte limit, and cuts on a character boundary.
- Two tools with one name are rejected at session start.
- Truncation holds when one line is larger than the byte limit.
- A `rescue error in ErlangError` also catches the exceptions that the BEAM normalizes, such as `SystemLimitError` and `ArgumentError`, and these have no `:original` field. Format a caught exception with `Exception.message/1`, never with a field of one exception type (#141).
- A tool never loads unbounded input or buffers unbounded output. A model-chosen path can be a device or a huge file; a command can write forever. A result that dropped output says so.
