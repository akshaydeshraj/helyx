# Transcript shape and session file format

Helyx needs one transcript shape that both model providers and harness providers can write into, and one file format that survives restarts. We use a provider-neutral message shape with three message kinds (user, assistant, tool result) and four content blocks (text, thinking, tool call, image), and we store sessions as append-only JSONL where every entry has an id and a parent id. The shape is taken from pi (earendil-works/pi), which already round-trips Anthropic and OpenAI without loss. The parent id costs one field now and allows branching later without a format change.

## Considered options

- Use the OpenAI chat format directly. Rejected: thinking blocks and image tool results do not map without loss.
- Flat JSONL without parent ids. Rejected: adding branching later would require a migration.
