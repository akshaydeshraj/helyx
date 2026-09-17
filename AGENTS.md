# AGENTS.md

Instructions for coding agents that work in this repository. `CLAUDE.md` is a symlink to this file.

## Project

Helyx is a BEAM-native substrate for malleable software. It is an Elixir framework for agent-native, stateful products. Read `README.md` for the architecture.

Key design constraints:

- Core stays small. It contains only plugin registration, OTP supervision, and interface dispatch.
- Everything else is a plugin: memory, tools, model context, compaction, transports, user interfaces.
- The extension surface is small: Provider, Tool, ModelContext, Compaction, Event, and one Transport.
- The server owns agent and session state. Clients are thin and render from the event stream.
- Local mode runs server and TUI in one BEAM node with OTP messages. Phoenix is not in core; it arrives later as a Transport plugin.

First checkpoint: a terminal coding agent (pi.dev style) built on these primitives.

## Repository layout

```text
AGENTS.md          Agent instructions (this file). CLAUDE.md symlinks here.
CONTEXT.md         Domain glossary (created lazily by /domain-modeling)
docs/
  adr/             Architecture decision records: NNNN-<slug>.md
  agents/          Per-repo config for the engineering skills
  devlogs/         Dated work logs: YYYY-MM-DD-<topic>.md
  features/        One design doc per feature, written before implementation
  reviews/         Code review outputs and follow-ups
lib/helyx/         Helyx core, interfaces, session, and message shapes
test/              Tests, mirrors lib/. test/support/ holds test-only plugins
plugins/<name>/    Bundled plugins, one Mix project each, path dependency on the root
apps/<name>/       Products, one Mix project each (planned)
```

## Commands

Run from the repository root. Plugins are separate Mix projects; the root `precommit` alias runs theirs too.

- `mix test`: run all tests
- `mix test path/to/file_test.exs:123`: run one test by line number
- `mix format`: format code
- `mix precommit`: alias for format, compile with warnings as errors, and test, in the root and in every plugin. Run it before you finish any change.
- `cd plugins/<name> && mix test`: run one plugin's tests

## Elixir guidelines

- Elixir has no `return` statement and no early return. The last expression in a block is the value.
- Use pattern matching and multiple function clauses over conditional logic.
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail. Reserve exceptions for unexpected states.
- Use structs over bare maps when the shape is known.
- Name processes only when necessary; pass pids or use Registry.
- Prefer `GenServer.call/3` over `cast/2` so callers get back-pressure.
- Do not add parentheses to keyword-style macro calls (`field :name, :string`, `plug :foo`).
- Tests end with `_test.exs` and mirror the `lib/` structure. Prefer async tests (`use ExUnit.Case, async: true`) unless the test touches shared state.
- Write `@moduledoc` and `@doc` for public modules and functions. Use `@moduledoc false` for internal modules.
- Prefer `Req` for HTTP; avoid `:httpoison`, `:tesla`, and `:httpc`.

## Module naming

- Core is `Helyx.Core`. An interface is `Helyx.<Interface>`, for example `Helyx.Provider`. A product uses its own root, for example `Acme`.
- A plugin is `<Root>.<Interface>.<Name>`. The root tells you who owns the code:
  - Bundled plugins use the `Helyx` root: `Helyx.Provider.Anthropic`, `Helyx.Tool.Shell`, `Helyx.Transport.Local`.
  - External plugins use their own root: `Acme.Provider.Bedrock`. Do not define modules under `Helyx.*` outside this repo. Module names are global in a BEAM node, and two packages that define the same module fail to compile together.
- Core resolves a plugin by its registration entry and a behaviour check, not by its module name. The module path is a reading aid only.
- An interface module such as `Helyx.Provider` stays a pure behaviour and public API. It never becomes a default implementation. Implementations live one level below it.

## Docs conventions

- **Devlogs** (`docs/devlogs/`): one file per work session, named `YYYY-MM-DD-<topic>.md`. Record what was done, what broke, and what is next.
- **Features** (`docs/features/`): one file per feature, named `<slug>.md`. Write the design before the implementation. State the goal, the interface changes, and what stays out of scope.
- **Reviews** (`docs/reviews/`): outputs of code reviews, named `YYYY-MM-DD-<scope>.md`, with findings and their resolution.
- **Decisions** (`docs/adr/`): architecture decision records, named `NNNN-<slug>.md`, with context, decision, and consequences.

## Git conventions

- Every commit goes through `/ship`: simplify, review on three axes, `mix precommit`, commit. See `.claude/skills/ship/SKILL.md`.
- Conventional commits: `type(scope): message` (see existing history).
- Do not commit generated artifacts (`_build/`, `deps/`, `.elixir_ls/`).

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `akshaydeshraj/helyx` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Review checklist

Invariants the failure-path review axis checks. See `docs/agents/review-checklist.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
