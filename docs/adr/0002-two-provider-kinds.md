# Two provider kinds: model and harness

The user has Claude and Codex subscriptions and no API keys. Anthropic does not permit third-party programs to call its API with subscription credentials, but it does permit a user to sign in to the unmodified Claude Code binary. OpenAI documents the Codex app server for third-party clients. So the Provider interface admits two kinds. A model provider calls a model API, and Helyx runs the turn and the tools. A harness provider drives an external agent program over stdio and records what it did. Both write into the same transcript and emit the same events.

## Consequences

- During a harness turn, Helyx tools are not visible to the model. The harness uses its own tools. Exposing Helyx tools to a harness needs an MCP server and is a later change.
- The first model provider speaks the OpenAI wire format. There is no Anthropic Messages implementation, because the user has no API key to test it with.
