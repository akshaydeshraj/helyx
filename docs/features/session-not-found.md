# Session not found, and client start errors

## Goal

A client that calls a session that is not running gets an error value, not an exit. A client that starts or resumes a session gets a start error from a closed list. Issue #188, from ADR 0006, section 2 and Consequences, ticket 1.

User story: I keep the TUI open, and the session behind it ends. When I press Enter, the TUI does not crash with a `noproc` exit. The text stays in the composer, and the status bar says that the session ended. A remote client that starts a session with a bad tool gets `{:start_failed, text}`, and the server log has the full reason.

Today:

- `Helyx.Session.subscribe/1` registers the caller in the events Registry and then calls the session. For a session that is not running, the call exits, the caller crashes, and the registration stays until the caller ends.
- `prompt/2`, `steer/2`, `follow_up/2`, `abort/1`, and `set_model/2` exit the same way.
- `Helyx.TUI.mount/1` checks with `Session.pid/1` that the session is alive before the subscribe, and catches the exit of the subscribe.
- `start/2` and `resume/2` can return any term, for example a supervisor error that holds a module.

## Interface changes

### A session that is not running

`Helyx.Session` sends every operation of the contract through one private function, `call/3`. It catches the exit of `GenServer.call/3` and returns `{:error, :session_not_found}` for every exit reason except `:timeout`:

- `:noproc`: no process has the id in the sessions Registry, because the session ended or never existed. The Registry removes the name of a dead process asynchronously, so a call to a dead pid that is still registered exits with `:noproc` too (the monitor of the call).
- Any other reason: the session process died during the call. The session ended, so the reply is the same. The supervisor logs the crash, so no reason is lost.
- `:timeout`: the session is running but did not answer in time. This is not a missing session, so the exit goes on to the caller, as before.

Changed specs:

```elixir
@spec subscribe(t()) :: {:ok, Snapshot.t()} | {:error, :session_not_found}
@spec prompt(t(), String.t()) :: :ok | {:error, :turn_running | :invalid_utf8 | :queue_full | :session_not_found}
@spec steer(t(), String.t()) :: :ok | {:error, :invalid_utf8 | :queue_full | :session_not_found}
@spec follow_up(t(), String.t()) :: :ok | {:error, :invalid_utf8 | :queue_full | :session_not_found}
@spec abort(t()) :: :ok | {:error, :session_not_found}
@spec set_model(t(), String.t()) :: :ok | {:error, model_error() | :session_not_found}
```

`subscribe/1` registers the caller, then calls the session. The order register, then snapshot, stays (`docs/features/session-snapshot.md`). A caller holds at most one registration for a session: the events Registry has duplicate keys and sends an event once for each entry, so a second entry would deliver each event twice. A second subscribe from the same process, a reconnect for example, does not register again; it gets a new snapshot, which replaces the state of the client (ADR 0006, section 3).

A session can send events to the new registration and then die before it answers the snapshot call. These events have no snapshot to order them, and a resume uses the same session id again, so a client that subscribes after the resume could apply them as live. So when the call returns `{:error, :session_not_found}`, `subscribe/1` removes the caller's registration for the id (`Registry.unregister/2`) and every `{:helyx_event, event}` of the id from the caller's mailbox, then returns the error. This includes the registration and the unread events of an earlier subscribe of the same process: the session is not running, and a new subscribe replaces what the earlier one gave. Review round 2 found that a rule that kept an earlier registration left each event twice (`docs/reviews/2026-09-27-188-session-not-found.md`).

`subscribe/1` owns the state of the caller for the session: its entry in the events Registry and the `{:helyx_event, event}` messages of the id in its mailbox. Every subscribe starts clean, and every failed subscribe leaves clean (review round 3 found a third path on this mechanism, so the rule covers all paths, not one):

- **Start:** before it registers, `subscribe/1` drops every event of the id in the mailbox. The snapshot holds the state of each such event of the running session. An event of an earlier instance has no snapshot to order it: a resume starts the session with the same id and `seq` 0 again, so the rule "drop `seq <= snapshot.seq`" would apply an old event as live.
- **Failure:** on `{:error, :session_not_found}`, and on an exit of the snapshot call (`:timeout`), `subscribe/1` removes the entry and drops the events of the id again. After a timeout the exit goes on to the caller, and the caller subscribes again to get events.

Accepted hole: a resume can start a new instance with the id while a subscribe fails against the old one. The new instance can read the caller's entry before the unregister and send an event after the drop, so one event of the new instance can stay in the mailbox. The next subscribe drops it at its start. Review round 3 ran resume and stop against subscribe for 15 s and saw no such event.

A text that is not UTF-8 still returns `{:error, :invalid_utf8}` before the call, and a model ref that does not resolve still returns its model error before the call. So these errors win over `:session_not_found`.

`model/1` is not in the contract (ADR 0006, section 2) and keeps its exit.

### Start errors for a client

The mapping lives in one public function of `Helyx.Session`, so every transport uses the same one:

```elixir
@spec client_start_error(term()) :: client_start_error()
@type client_start_error ::
        :invalid_cwd | :not_found | model_error() | {:start_failed, String.t()}
```

- `:invalid_cwd`, `:not_found`, `{:unknown_provider, id}`, and `{:bad_provider_turn, id}` pass unchanged. `start/2` never returns `:not_found`; only `resume/2` does.
- `{:invalid_model_ref, ref}` passes only when the ref is within the bounds of `Helyx.ModelRef`: valid UTF-8 of at most 256 bytes, with no whitespace and no character of Unicode category C (`Helyx.ModelRef.bounded?/1`, which `parse/1` also uses). Such a ref failed to parse only for its form, a missing slash or an empty part, and it is safe to print. On a resume the ref comes from the session file, which can hold up to 64 MiB. Any other ref becomes `{:start_failed, text}`, and the log has it.
- Any other term becomes `{:start_failed, "the session did not start; the server log has the reason"}`. The function logs the full term as a warning.
- `start/2` and `resume/2` do not change: the product gets the full term. A transport calls `start/2` or `resume/2`, then gives the client the result of `client_start_error/1`.

The text is fixed. A reason can hold a path, a module, or an exception message from a plugin, and a remote client must not get these. The log has them.

### The TUI

- `mount/1` calls `subscribe/1` first. On `{:error, :session_not_found}` it exits with `{:session_down, :session_not_found}`. The `try` and the alive check before the subscribe are gone.
- The monitor still needs a pid (ticket 2 of ADR 0006 removes it). After the subscribe, `mount/1` reads the pid with `Session.pid/1`. A session that ended between the subscribe and this read gives `nil`, and the mount exits with `{:session_down, :session_not_found}` too, so one state has one reason. A session that ends after the monitor is set gives a `:DOWN`.
- A steer or a follow-up that returns `{:error, :session_not_found}` keeps the text in the composer, and the status bar says "not sent: the session ended". The `:DOWN` of the monitor then ends the TUI.
- `/model` that returns `{:error, :session_not_found}` shows the notice "the session ended". The helper that makes the notice text is `switch_error/1`, not `model_error/1`, because it now also names this error.

`CodingAgent.run/1` drops the `try` around `Session.abort/1`, because the abort of an ended session now returns an error.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| each operation call | `GenServer.call` with the default 5,000 ms timeout; `abort/1` waits with `:infinity`, as before | `Helyx.Session` | a timeout exits, as before; a subscribe first removes its entry and the events of the id |
| `{:start_failed, text}` | a fixed text of 56 bytes | `Helyx.Session.client_start_error/1` | n/a |
| `{:invalid_model_ref, ref}` | the bounds of `Helyx.ModelRef`: 256 bytes of valid UTF-8, no whitespace, no category C character | `Helyx.Session.client_start_error/1` through `Helyx.ModelRef.bounded?/1` | `{:start_failed, text}`, and the log has the ref |
| `{:unknown_provider, id}`, `{:bad_provider_turn, id}` | the provider id of a parsed ref, which `Helyx.ModelRef` bounds | `Helyx.ModelRef.parse/1` | n/a |
| log line of a start error | the full term through `inspect/1` with its default limits. The limits apply to each collection, not to the whole line, so a deeply nested term makes a long line | `Helyx.Session.client_start_error/1` | `inspect/1` cuts each long list or binary with `...` |
| registrations of one caller for one session | one | `Helyx.Session.subscribe/1` | a second subscribe does not register again |
| mailbox drop at each subscribe and each failed subscribe | the events of the id already in the caller's mailbox; a selective receive with `after 0` | `Helyx.Session.subscribe/1` | n/a: the drop stops at the first scan with no event of the id |
| TUI texts | "not sent: the session ended" and "the session ended" are fixed | `Helyx.TUI` | n/a |

## Ownership

No new resource. A subscribe to a session that is not running removes the caller's entry for the session in the events Registry, and the events of the session in the caller's mailbox, before it returns.

## Out of scope

- The end signal, and a TUI that does not use `Session.pid/1`: ticket 2 of ADR 0006.
- `contract_version` in the snapshot: ticket 3.
- A transport that uses `client_start_error/1`: the first remote transport.
- An event of an earlier instance for a remote client. The mailbox drop of `subscribe/1` reaches only a local client. A remote transport that buffers events of an old instance needs `seq` that continues across a resume, or an instance id in `Helyx.Event` and in the snapshot. This is an interface change for the owner to decide, with the end signal (ticket 2 of ADR 0006) or the first remote transport.
- A text of `{:start_failed, text}` that names the reason. Add it when a person needs more than the log.
