# Helyx Core cleanup plan

2026-09-26 · Akshay Deshraj

## Purpose

This plan lists the places where Helyx Core does more than one job, and the order in which to separate them. It serves the first design constraint of `AGENTS.md`: Core contains only plugin registration, OTP supervision, and interface dispatch.

Each item here is a candidate, not a decision. An item that changes an interface gets a feature doc from `docs/features/TEMPLATE.md` before any code. An item that reopens an ADR says so. Each item then becomes a ticket and goes through `/implement` and `/ship`.

Source revision: `afefad2` on `master`, 2026-09-26.

## Task 1: take the provider stream out of `Helyx.Session`

`Helyx.Session` (998 lines, the largest file) holds two turn engines in one module: the model loop and the harness bookkeeping. About 70 lines refer to `harness` or `kind`, spread over `handle_call`, `handle_info`, `start_provider_call`, and `consume`. You cannot read the model loop without also reading the harness rules.

**Evidence**

- `consume/4`, `harness_event/1`, `done_terminal/2`, `capped_usage/1`, and `forward/5` turn a raw provider stream into session messages (`lib/helyx/session.ex:739-829`).
- The `kind` field is on `State` and on `Turn`, and it switches five behaviours: a steer that aborts, calls that are recorded and not run, the harness session id, the stream as a Task of the hands, and the truncation of harness results.
- The architecture review of 2026-09-25 named the same candidate: one module for the provider stream.

**Proposed seam**

One module takes a provider stream and gives the session validated events and one terminal. It holds the shape checks of stream events and the harness event translation. The session keeps the state, the queues, the transcript, and every decision.

Some input does not come through the stream. Keep a check at each of these boundaries, or let each boundary call one shared validator:

- A `:DOWN` reason of a Task crash (`session.ex:474`). It arrives with no normal stream return.
- A `:stream_end` terminal from the hands (`session.ex:479`).
- The return value of the provider call (`session.ex:681`).
- Client text in `prompt/2`, `steer/2`, and `follow_up/2` (`valid_utf8?/1`, `session.ex:227-256`). This check stays in the public API.

**Provider capabilities**

The `kind` flag is Task 5, a separate ticket after Task 1. Task 1 does not change it.

**Bounds and ownership**

No new input, buffer, or wait. The bounds rows for the stream (the integer cap, the harness line cap) move with the code. The provider stream Task row of the ownership table does not change.

## Task 2: move the tool text helpers out of Core

About 200 of the 259 lines of `lib/helyx/tool.ex` are text utilities that only plugins need: `truncate/2,3`, `read_file/1`, and the UTF-8 edge rules (`clean_edge/2`, `whole_edge?/2`, `without_edge/3`). They belong in a helper module of `plugins/bundled`, like `Helyx.Watchdog` (ADR 0005).

**Callers today**

| Caller | Uses |
| --- | --- |
| `Helyx.Tool.Read` | `read_file/1`, `truncate/3` |
| `Helyx.Tool.Edit` | `read_file/1` |
| `Helyx.Tool.Bash` | `truncate/2` |
| `Helyx.ModelContext.Default` | `read_file/1`, `truncate/2` |
| `Helyx.Session` (Core) | `truncate/2` on harness tool results, `session.ex:797` |

**Prerequisite**

The one Core caller holds the code in Core, because Core cannot call into `plugins/bundled`. The move changes the `Helyx.Provider` contract. Today the moduledoc says that the session cuts the text of every `{:tool_result, ...}` event (`Helyx.Tool.truncate/2`, `:tail`). `test/helyx/session_test.exs:247` tests this with a test provider. After the move, every provider cuts its own results, not only ClaudeCode and Codex.

Before the helpers move:

1. Change the `Helyx.Provider` moduledoc: each provider cuts the text of its tool results to the tool result limits before it sends them.
2. Make `Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex` cut their results, as the bash tool does. Add a truncation test for each.
3. Replace the session test at `session_test.exs:247` with a test of the Core rule for an oversized result.
4. Add the Core check for a result that is too large (decided below).

**Decision: an oversized result fails the turn at the stream boundary**

- The provider owns truncation, the line selection, and the truncation notice.
- Core checks a separate maximum byte size before it forwards the result to the session. The check is small, and a provider that breaks the contract becomes visible.
- The feature doc defines the maximum. It is not `51,200`, because the text that a provider sends also holds the truncation notice.
- The feature doc says whether the check runs before or after the UTF-8 repair, because the repair can make the text larger.
- The error is `{:tool_result_too_large, actual_bytes, limit}`. It does not hold the rejected text.
- The turn fails through the existing failed-turn path, which closes the open calls and releases the resources.
- A test shows that the session accepts another prompt after this failure.

**Result**

`Helyx.Tool` keeps only the behaviour, `hold/1`, `by_name/1`, and `spec/1`. Core loses about 200 lines. The architecture review of 2026-09-25 named this candidate too.

**Bounds and ownership**

The limits (2000 lines, 51,200 bytes, 10 MiB per file) do not change. The row "Harness tool result text" in `docs/features/coding-agent.md` changes: the provider cuts the text, not the session. The property tests of `truncate` move with the code. No external resource.

## Findings from the dependency graph

`mix helyx.graph calls` gave 623 call edges and `mix helyx.graph turn` traced one scripted turn with the read tool. The graph confirms Tasks 1 and 2 and shows six smaller items. It cannot see calls through a plugin interface (a module in a variable), messages outside the traced turn, or compile-time calls (a function called in a module attribute or a moduledoc).

| # | Finding | Evidence | Proposed change | Size |
| --- | --- | --- | --- | --- |
| G1 | Provider input checks are spread over the session | `Message.cap_integers/1` is called from 5 session functions: `consume/4`, `capped_usage/1`, `harness_event/1`, `start_provider_call/1`, `handle_info/2`. `encodable?/1` and `valid_utf8?/1` are called from 2 and 3 more | Put the stream event checks in the stream module of Task 1. Keep a check at each other boundary (see Task 1) | Part of Task 1 |
| G2 | The file format owns rules of the message shape | `Session.harness_event/1` calls `SessionFile.harness_id?/1`. The `Helyx.Provider` moduledoc says the stop-reason set is owned by `SessionFile` | Move the stop-reason set and the id rule to `Helyx.Message`. `SessionFile` only encodes them | Small |
| G3 | Each provider call reads the plugin table through an Agent | The turn Task calls the `Plugins` Agent twice per provider call: `ModelContext.build/3` and `Compaction.compact/3` each resolve their plugin. The provider itself is resolved once, at start | Resolve the single-mode plugins once at session start, as for the provider | Small |
| G4 | Harness providers use two layers for the watchdog | `Codex` calls `Watchdog.write/2` and `Watchdog.release/4` directly, and `ClaudeCode` calls `Watchdog.close/1`, next to their calls into `HarnessIO` | Decide one layer: `HarnessIO` wraps every watchdog call, or providers call `Watchdog` and `HarnessIO` keeps only the text rules | Small |
| G5 | A plugin depends on the session runtime | `Provider.Fake.run_tool/3` calls `Session.start/2`, `subscribe/1`, and `prompt/2`. Only the four tool tests use it | Move `run_tool/3` to a test support module of `plugins/bundled` | Small |
| G6 | Functions with no caller (withdrawn) | The graph showed no caller. But `Message.max_integer_digits/0` builds `@rejected_call_text` (`session.ex:69`), and `HarnessIO.replay_max_bytes/0` is in the moduledocs of `ClaudeCode` and `Codex`. `Hands.cancel/2` is used in tests only | No change. Keep all three | None |

Question from the trace: `ModelContext.Default` reads the `AGENTS.md` files from disk on every provider call, so it picks up edits during a turn.

**Decision: keep the current behaviour in this cleanup.** The session builds the context and runs compaction before every provider call (`session.ex:653-668`). Each call gets the latest transcript. A context built once per turn would leave out new tool results and steers. The new read of `AGENTS.md` is a policy of the plugin. Keep it, and document that an edit takes effect at the next context build. A later cache holds only the file content and states when that content expires.

## Task 3: break `Helyx.Session` into smaller modules

Split `lib/helyx/session.ex` (998 lines) into 6 modules. Tasks 1 and 2 remove only about 110 lines, so the file stays too large without this task. The module count and the line counts below are estimates, not targets.

The task is done when the behaviour is the same. The existing session tests must pass with no change to their assertions, and they must cover:

- the order of events, from `agent_start` to `agent_end`, for model and harness turns
- abort cleanup: every open call gets its aborted result, and the hands release every held resource
- resume: a session resumed from its file gives the same transcript and the same harness session id

The current file has these parts:

| Part | Lines (approx.) |
| --- | --- |
| Moduledoc, `State`, `Turn` | 125 |
| Public API with docs | 180 |
| GenServer callbacks | 230 |
| Turn loop | 180 |
| Stream consumption | 110 |
| Transcript queries | 50 |
| Emit, persist, `drop_unknown` | 50 |
| Assistant message building | 40 |
| Queue rules | 35 |

The proposed modules:

| Module | Holds | Pure | Lines (approx.) |
| --- | --- | --- | --- |
| `Helyx.Session` | Client API, docs, start and resume wiring, `resolve_model/2` | No | 250 |
| `Helyx.Session.Server` | GenServer callbacks and the turn loop | No | 380 |
| `Helyx.Session.Stream` | Task 1: the context build, `provider.stream`, and the stream event checks | No | 120 |
| `Helyx.Session.Turn` | The struct as a real module: `add_block/2`, `assistant_message/2`, `reject/2`, `rejected?/2` | Yes | 60 |
| `Helyx.Session.Transcript` | `open_calls/1`, `last_assistant/1`, and the harness resume rule | Yes | 60 |
| `Helyx.Session.Queues` | `push/3` returns `{:ok, q}` or `{:error, :queue_full}`; `drain/1`, `counts/1`, `clear/1` | Yes | 45 |

The line count is not the real source of complexity. The real source is the matrix of 3 modes (idle, turn, aborting) and the message types. Also, `kind == :harness` branches occur in 5 places: steer, `start_provider_call`, `start_stream`, `consume`, and `end_turn`. Task 5 removes those branches.

Do the work in this order:

1. Extract `Queues`, `Turn`, and `Transcript`. These are pure extractions with no interface change.
2. Extract `Stream`. This is Task 1.
3. Split `Session` and `Server`, and move the session runtime into `lib/helyx/session/`. Do this last, because it is a mechanical move.

In step 3, the modules of the session runtime also move under `Helyx.Session`. In `session/`, the path follows the module name, so these modules get new names:

| Today | After step 3 | Callers outside `lib/helyx/` |
| --- | --- | --- |
| `Helyx.Hands` (`lib/helyx/hands.ex`) | `Helyx.Session.Hands` (`lib/helyx/session/hands.ex`) | `test/helyx/hands_test.exs`, `plugins/bundled/test/helyx/provider/openai_test.exs`, `apps/coding_agent/test/mix/tasks/helyx.graph_test.exs` |
| `Helyx.SessionFile` (`lib/helyx/session_file.ex`) | `Helyx.Session.File` (`lib/helyx/session/file.ex`) | `test/helyx/session_file_test.exs`, `test/helyx/session_test.exs`, `plugins/bundled/test/helyx/provider/claude_code_test.exs`, `plugins/bundled/test/helyx/provider/codex_test.exs`, `apps/coding_agent/lib/coding_agent.ex`, `apps/coding_agent/test/mix/tasks/helyx_test.exs` |
| `Helyx.Id` (`lib/helyx/id.ex`) | `Helyx.Session.Id` (`lib/helyx/session/id.ex`) | None |

This is a rename of public modules, not only a file move. The old names are removed, with no alias and no delegate module. Helyx has no release, and every caller is in this repository, so a compatibility module only adds dead code. The same ticket updates every caller in the table, in all three Mix projects. `mix precommit` from the root runs the tests of `plugins/bundled` and of each app, so a missed caller fails the gate. `mix helyx.graph` is untracked today. If it merges first, its test changes with the rename.

The current docs that name the old modules change too: the `Helyx.Provider` moduledoc, `docs/features/coding-agent.md`, and `docs/features/tool-resource-release.md`. The ADRs do not name these modules. The glossary term **Hands** in `CONTEXT.md` stays. Devlogs and reviews are dated records, so they keep the old names. The test files move to `test/helyx/session/`.

Stop at these modules. Do not split the server per `handle_info` group, because that spreads one state machine over many files. Credo `CyclomaticComplexity` in `mix precommit` already guards each function.

## Task 5: replace the `kind` flag with named provider behaviour

After Task 5, Core knows what a provider does, not the word "harness". This follows the first design constraint: Core knows interfaces, not specific kinds of provider. The task reopens ADR 0002 and changes the `Helyx.Provider` contract, so it gets a feature doc first.

Today the `kind` flag switches four behaviours together:

- no message in the middle of a turn: a steer aborts the turn
- calls that arrive with their results: the session records them and does not run them
- an opaque provider state entry: the harness session id
- OS resources held with the hands: the stream runs as a Task of the hands

Each harness provider has all four, and each model provider has none. Four separate flags allow 16 combinations, and only 2 of them are real. The other 14 have no test and no user. So the feature doc starts from the code after Task 1 and asks one question for each behaviour: does a provider need it without the others?

- **A behaviour is needed alone:** it becomes a separate capability, with its own test.
- **The behaviours always go together:** keep one flag, but name it by its behaviour, for example `turn: :external` (the provider runs the tools, and the session only records them). All its branches stay behind `Helyx.Session.Stream`.

Each result removes the word "harness" from Core and updates ADR 0002. Neither adds a combination that nobody uses.

**Order:** after Task 1 and before Task 3 step 3. The server is then split once, after the `kind` branches are gone. If the order is reversed, the branches move in the split and then change again in the new files.

**Done when:** no `kind == :harness` branch is left in Core, the session tests pass with no change to their assertions, and ClaudeCode and Codex declare the new contract.

## Task 4: group the interfaces and the data shapes in folders

Move the files of the interfaces into `lib/helyx/interfaces/` and the files of the data shapes into `lib/helyx/data/`. The module names do not change. The compiler finds a module by its `defmodule` line, not by its path. The top level of `lib/helyx/` then shows the parts of Core at a glance.

| Folder | Files | Modules (no change) |
| --- | --- | --- |
| `interfaces/` | `interface.ex`, `provider.ex`, `tool.ex`, `model_context.ex`, `compaction.ex`, `event.ex` | `Helyx.Interface`, `Helyx.Provider`, `Helyx.Tool`, `Helyx.ModelContext`, `Helyx.Compaction`, `Helyx.Event` |
| `data/` | `message.ex`, `context.ex`, `model_ref.ex` | `Helyx.Message`, `Helyx.Context`, `Helyx.ModelRef` |

The layout of Core after Tasks 3 and 4:

```text
lib/helyx/
  core.ex, core/plugins.ex
  interfaces/   interface.ex provider.ex tool.ex model_context.ex compaction.ex event.ex
  data/         message.ex context.ex model_ref.ex
  session.ex
  session/      server.ex stream.ex turn.ex queues.ex transcript.ex hands.ex file.ex id.ex
```

The module names stay because a rename to `Helyx.Interface.Compaction` breaks the naming rule of `AGENTS.md` (`Helyx.<Interface>`, `<Root>.<Interface>.<Name>`) and every external plugin. The cost of the move is one exception to the rule "the path follows the module name".

The same ticket:

- Adds this rule to the module naming section of `AGENTS.md`: "The path follows the module name, except in `lib/helyx/interfaces/` and `lib/helyx/data/`. These two folders group files only. They are not part of the module name."
- Moves the tests to `test/helyx/interfaces/` and `test/helyx/data/`, so the tests still mirror `lib/`.
- Updates each path in the docs that names a moved file, for example `lib/helyx/tool.ex` in this plan.

The task changes no code, so it can run at any time. It runs alone, because each open branch that edits a moved file gets a rebase conflict. Task 2 edits `tool.ex`, so do Task 4 before Task 2, or after it merges.

## Keep, and next steps

These couplings are deliberate and documented. Keep them:

- `Helyx.Hands` hosts harness programs as well as tools. ADR 0003 and ADR 0004 require every OS process to be held with the hands, so abort waits until it is gone.
- `Helyx.Watchdog.release/4` delegates to `Helyx.Watchdog.Group`. The plugins call the helper, not its internal module (ADR 0005).
- `Helyx.Session` calls `Helyx.SessionFile` for every append. The session decides; the file records.

Next steps:

- [ ] Decide the order. Recommended: Task 4 first, alone (moves only), then G2 (small, no interface change), then Task 3 step 1, then Task 1 (Task 3 step 2), then Task 5, then Task 3 step 3. Task 2 runs after Task 1, because both change `harness_event/1`.
- [x] Write a feature doc for Task 1 (`docs/features/session-stream.md`) and for Task 2 (`docs/features/tool-text-out-of-core.md`).
- [ ] Write a feature doc for Task 5 after Task 1 merges.
- [ ] Document in `ModelContext.Default` that an edit of `AGENTS.md` takes effect at the next context build.
- [ ] File one ticket for each accepted item.

## Tickets

| Plan item | Issue |
| --- | --- |
| Task 4: folders | #117 |
| G2: rules to `Helyx.Message` | #118 |
| Task 3 step 1: `Queues`, `Turn`, `Transcript` | #119 |
| Task 1: `Helyx.Session.Stream` | #120 |
| Task 2: tool text out of Core | #121 |
| G3: resolve plugins once | #122 |
| Task 5: named provider behaviour | #123 |
| Task 3 step 3: split and renames | #124 |
| G4: one watchdog layer | #125 |
| G5: `Fake.run_tool/3` to test support | #126 |
