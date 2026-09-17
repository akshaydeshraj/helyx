# Review checklist

Invariants the failure-path review axis checks on every diff. Add one when a review or a PR comment finds a defect that a checklist line would have caught.

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
