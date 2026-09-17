# 2026-09-17: checkpoint one skeleton (ticket #2)

## Done

- Root `helyx` Mix project. Elixir 1.19.5 and OTP 28.5.0.6 pinned in `.tool-versions`. `mix precommit` formats, compiles with warnings as errors, and tests the root and every plugin.
- `Helyx.Interface`: `use Helyx.Interface, mode: :single | :multi, required: bool`. Core reads the declaration and the `@behaviour` attributes of each plugin.
- `Helyx.Core`: a Supervisor started from a child spec with `plugins:`. It resolves the plugin list before starting, so a mode violation, a missing required plugin, or a module with no interface is a `start_link` error. It supervises a plugin registry, a sessions Registry, an events Registry, a Task.Supervisor, a DynamicSupervisor for sessions, and any plugin that exports `child_spec/1`. Several Cores can run in one node under different names.
- `Helyx.Provider`: the first interface, `multi` and required. `id/0` and `stream/3`, which returns an enumerable of `{:text_delta, _}`, `{:done, _}`, and `{:error, _}`.
- `Helyx.Session`: one GenServer per conversation under Core's DynamicSupervisor, found through Registry. `start/2`, `subscribe/1`, `prompt/2`. A turn runs the provider stream in a Task; the Task sends stream events to the session; the session builds the assistant message and emits events with session id, turn id, and sequence number. Stream events for a turn that is no longer current are dropped.
- `Helyx.Message`, `Helyx.Message.Text`, `Helyx.Context`, `Helyx.Event`, `Helyx.ModelRef`.
- `plugins/provider_fake`: `Helyx.Provider.Fake` in its own Mix project. The `echo` model streams the prompt back one word per delta. Scripted models replay responses registered with `script/3`, stored in an Agent that Core starts per instance.

## Decisions made while building

- The Fake provider depends on Helyx, so Helyx cannot depend on it. The session seam tests live in the Fake plugin's test suite. Root tests cover Core boot with tiny test-support interfaces and plugins.
- The user message also gets `message_start` and `message_end` events, so a second client can render it. The ticket listed seven event types; the emitted sequence is those seven with the two user message events after `turn_start`.
- Core checks a fixed list of bundled interfaces at boot, plus every interface a plugin implements. A first version scanned loaded modules for interfaces. The review found that this made the required check depend on module load order, so it was replaced.
- Session state and the turn in progress are structs. The provider Task forwards text deltas and returns the first `done` or `error` as its reply. A stream with no terminal event fails the turn with `:stream_ended`; a Task crash fails it with `{:task_exit, reason}`.
- The provider lookup by model ref prefix lives in `Helyx.Provider.find/2`, so Core knows nothing about any one interface.
- Provider stream events are tuples for now. They become structs when tool calls arrive in ticket #3.

## Review

`docs/reviews/2026-09-17-issue-2.md` records the review findings and what changed because of them.

## Broke

- The first precommit run failed because the alias ran `mix test` in the dev environment. Fixed with `def cli do [preferred_envs: [precommit: :test]] end`.
- The shell used by the agent does not activate mise, so `erl` resolved to Homebrew's OTP 29. Under `mise exec` the pinned OTP 28 is used. Interactive shells with mise activated are unaffected.

## Next

- Ticket #3: hands and the four tools.
- Tickets #7 and #8 can start in parallel once #2 is closed.
