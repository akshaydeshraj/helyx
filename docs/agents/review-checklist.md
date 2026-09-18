# Review checklist

Invariants the review axes check on every diff. Add one when a review or a PR comment finds a defect that a checklist line would have caught. The failure-path brief in the ship skill names the probe categories; the lines here are the invariants the probes must not break.

## Specs and bounds

- The feature doc states the bound of every input, buffer, and wait, or says "unbounded, ticket #N". The spec axis checks that table against the diff.
- Any numeric limit in code has a property test or, at minimum, tests at the limit, one under, one over, and a multibyte case.
- Every `ponytail:` marker names a ticket. Judge whether the debt is safe to ship, not only whether it is recorded.
- A design decision that the tools research (`docs/research/coding-tools.md`, issue #17) covered cites it in the feature doc, so the spec axis can check the design against how codex, opencode, and pi behave.
- Every external resource in the diff (OS process, process group, port, file handle, socket, temp file) has a row in the feature doc's ownership table. A row whose holder is a Task is a design flag the spec axis raises (ADR 0004).

## Races and resource ownership

- A race is closed structurally or stated as a hole. It is never accepted by window size or by who the caller is today. An open race is written in the ownership table as "open, ticket #N", the same vocabulary as an unbounded input.
- Two findings on one mechanism stop the patching. The next round fixes the mechanism, not the path.
- An OS resource is owned by a long-lived process, never by a Task (ADR 0004). The owner is registered before the external work starts and releases the resource on delivery, on the holder's crash, and on abort.

## Events

- Every `message_start` gets a `message_end` on the same turn, on success and on failure.
- Every turn ends with `agent_end`, on success and on failure.
- Sequence numbers increase by one per event within a session, with no gaps.

## Sessions and turns

- A failure in a turn never crashes the session. The turn fails, the session accepts the next prompt.
- A message from a Task that is no longer current never touches the session.
- A stream that ends without a terminal event fails the turn.
- A partial assistant message from a failed turn is not added to the transcript.

## Plugins and Core

- Bad configuration returns `{:error, reason}` from `start_link`; it never raises. This includes a module that does not exist, two plugins for a single-mode interface, no plugin for a required one, and two providers with one id.
- Core knows no interface by name except the fixed list it checks at boot.

## Inputs from plugins

- A value from a plugin is checked by shape before it reaches a process that holds state. Match the whole tuple or struct, never elements by index.
- Providers are compiled into the node. Shape is checked; individual field values are not.

## Tools and hands

- A tool Task that dies without a result still produces a tool result, with `is_error` true.
- The tool calls of one assistant message run one at a time, in call order, so no two touch the working directory at once.
- Truncation holds for trailing blank lines, for a line exactly at the byte limit, and cuts on a character boundary.
- Two tools with one name are rejected at session start.
- Truncation holds when one line is larger than the byte limit.
- A tool never loads unbounded input or buffers unbounded output. A model-chosen path can be a device or a huge file; a command can write forever. A result that dropped output says so.
