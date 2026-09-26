# Two provider kinds: model and harness

The user has Claude and Codex subscriptions and no API keys. Anthropic does not permit third-party programs to call its API with subscription credentials, but it does permit a user to sign in to the unmodified Claude Code binary. OpenAI documents the Codex app server for third-party clients. So the Provider interface admits two kinds. A model provider calls a model API, and Helyx runs the turn and the tools. A harness provider drives an external agent program over stdio and records what it did. Both write into the same transcript and emit the same events.

## Consequences

- During a harness turn, Helyx tools are not visible to the model. The harness uses its own tools. Exposing Helyx tools to a harness needs an MCP server and is a later change.
- The first model provider speaks the OpenAI wire format. There is no Anthropic Messages implementation, because the user has no API key to test it with.

## Revision

2026-09-26: The two provider kinds are now one flag named by behaviour, `turn/0`: `:local` (the default) or `:external`. An external turn runs the whole turn and its own tools in one provider call. The session records the tool results and does not run the tools. The provider keeps its own conversation state, which the session resumes by id. The stream runs under the hands. A steer aborts the turn. Claude Code and Codex have external turns. The reasons of this decision do not change. The product term "harness provider" stays and names a provider with an external turn (#123).
