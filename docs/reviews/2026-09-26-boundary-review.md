# Boundary principle review

Date: 2026-09-26. Master at 7feadcb. Five read-only review agents, then five rounds of source review of this document.

## The principle

Check data where it comes in: at a **boundary**. Handle the error there. Inner code trusts that check and does not check again. When a state can come only from a bug, inner code crashes ("let it crash") and does not handle it.

The boundaries of Helyx:

- client input: the public API of `Helyx.Session`
- plugin output into Core: provider stream events, tool results, plugin callback returns
- the disk: the session file reader, and the files that tools read
- external programs and networks: Claude Code and Codex output, HTTP responses, bash output
- model data: tool call arguments, at the tool entry
- terminal input, application config

Two refinements from the discussion:

- The disk is a boundary. A file can come from an older version, from a manual edit, or from a crash in the middle of a write.
- A boundary check must fail in proportion. One bad optional value must not destroy more than itself.

TigerStyle (TigerBeetle) agrees on one point: inner code must not *handle* impossible states. It goes further and wants inner code to *assert* a lot. This review deletes inner handling. It does not add inner assertions.

Method: five read-only review agents, one for each area. Each finding names every caller and the upstream check with `file:line`. The orchestrator checked the main findings in the code again.

**Revision 4:** the wording of the bounds template. The fifth review found no blocking issue.

**Revision 3:** a fourth review made the T0 rules less absolute: repeated checks, fresh reads, and the scope of a failure. T8 now waits for T0.

**Revision 2:** a third review corrected the T2 contents (A2 is in T1), the order of T3 and T7 (both edit `tui.ex`), and the sources that E2 names.

**Revision 1:** a second source review corrected D1, C2, A7, E2, and the ticket order. Its main rule is now part of this review: **validate the exact value that later code uses.** A check on one value is useless when later code reads a new value from the same source.

## Summary

| Group | What | Count | Decision needed |
|---|---|---|---|
| A | Inner code that handles states that cannot happen: delete | 6 (A7 withdrawn) | none |
| B | The text repair is in the wrong place: move to the boundaries | 1 | which copy stays |
| C | Missing boundary checks: real bugs | 3 | none |
| D | Boundary checks that destroy too much | 4 | none |
| E | Checks that a doc or an earlier review requires | 3 (E2 settled: keep) | E1, E3 |

## A. Inner code that handles states that cannot happen

Nothing changes when Helyx works correctly. If a bug in Helyx makes one of these states, Helyx now fails loudly. Today it hides the bug.

### A1. The text checker looks inside lists and maps that never come

- **Where:** `lib/helyx/data/message.ex:127-146`, `valid_utf8?/1`
- **Today:** the helper walks structs, maps, and lists, and its catch-all returns `true` for `nil` or a number. Every caller passes one string:
  - `session.ex:176, 191, 205`, which have the `is_binary` guard
  - `model_ref.ex:31`
  - `stream.ex:81, 142`
  - `file.ex:97`
- **Change:** call `String.valid?/1` at each caller. Delete `valid_utf8?/1` and its test at `message_test.exs:17-24`.
- **Note:** this is a public function of `Helyx.Message`. No plugin calls it.

### A2. The model name is checked twice

- **Where:** `lib/helyx/session/file.ex:97`, the `model` half of the check
- **Today:** `Session.File.create` checks the model again. Its only caller (`session.ex:99`) passes `ModelRef.to_string/1` of a ref that `ModelRef.parse/1` accepted, and the parse already checked it.
- **Change:** delete the model half. The `cwd` half moves to C1.
- **Doc:** `docs/features/coding-agent.md:154` records this duplicate. The doc row changes.

### A3. The TUI distrusts the events that Core makes

- **Where:** `plugins/bundled/lib/helyx/tui/view_model.ex:82-150`, `apply/2`
- **Today:** there are `is_binary` and `is_integer` guards on each event, and a catch-all that ignores "malformed" events. Core makes every event from checked data:
  - `stream.ex:80-84, 141, 148`
  - `server.ex:131-134, 185, 363`
- **Change:**
  - Delete the guards. Keep `cut > 0`, which is a real rule.
  - Replace the catch-all with clauses for the events that the TUI ignores on purpose: `:turn_start`, `:turn_end`, a user `:message_start`, and `:agent_end` with another stop reason.
  - Delete the tests of the malformed path: `view_model_test.exs:310-327`, half of `:341-346`, and `:356`.
- **Visible effect:** if Core has a bug, the TUI crashes. Today it draws nothing.

### A4. The TUI has a message for an error that cannot happen

- **Where:** `plugins/bundled/lib/helyx/tui.ex:466-469`, `send_error(:invalid_utf8)`
- **Today:** the composer already rejects invalid text at `tui.ex:301-308`. The comment in the code says that the error "has no known source".
- **Change:** delete the clause.

### A5. Codex checks for a closed port that is never closed at that point

- **Where:** `plugins/bundled/lib/helyx/provider/codex.ex:188-189`, `interrupt/2`
- **Today:** the guard is `port != nil`. The only caller (`codex.ex:174`) runs only while `done?` is false. Every path that sets the port to `nil` also sets `done?` to true.
- **Change:** delete `and port != nil`.

### A6. The end-of-turn result is capped two or three times

- **Where:**
  - `lib/helyx/session/server.ex:220`
  - `lib/helyx/session/stream.ex:67`
  - `lib/helyx/session/stream.ex:170`
- **Today:** the stream caps the usage, then caps the whole result. The server then caps the result again. The only result that is new and not capped is the crash reason that the hands make at `hands.ex:259-260`.
- **Change:**
  - Cap the crash reason where the hands make it.
  - Delete the cap at `server.ex:220`.
  - Add one test with a crash reason that holds a very large integer.
- **Doc:** change `docs/features/session-stream.md:49, 52`.

### A7. Withdrawn: the bash tool keeps its NUL check on `cwd`

- **Where:** `plugins/bundled/lib/helyx/tool/bash.ex:71-72`
- **First finding:** the hands run `File.dir?/1` first (`hands.ex:270`), so the bash check never runs.
- **Why it is withdrawn:** a tool is public plugin API. `Tool.hold/1` is documented for tools that run outside the hands (`tool.ex:68`), and tests call `Bash.run/2` directly (`bash_test.exs:129`). The tool entry is a boundary for its whole context, not only for the model's arguments. A check at `Session.start/2` does not protect a direct call.
- **Change:** none.

## B. The text repair is in the wrong place

- **Where:** three copies:
  - `lib/helyx/session/hands.ex:359-361`
  - `lib/helyx/data/message.ex:92-99`
  - `plugins/bundled/lib/helyx/tui.ex:671-678`
- **Today:** tool text can hold broken bytes. The hands repair it, `Message.tool_result/2` repairs it again, and the TUI repairs it a third time. A tool result from Claude Code or Codex is not repaired at its boundary (`stream.ex:138-146`). Only the copy in `Message` protects that path.
- **The reviewers disagree:** one reviewer keeps the repair at the boundaries. Two reviewers keep the copy in `Message`, because every result passes through that one place.
- **Recommendation: repair at the two boundaries.**
  - The hands repair the output of tools. This stays.
  - `Stream.external_event/1` repairs each Claude Code or Codex result, after the 65,536-byte check, so that the check still measures the text as it was sent.
  - Delete the copies in `Message` and in the TUI.
  - Reason: this is your principle, and the second place (the stream) then says clearly that it is a boundary.
- **Tests:**
  - Add a stream test for an external result that is not valid UTF-8. No test covers that path today.
  - Move the TUI test at `tui_test.exs:417-428`.
- **Doc:** `coding-agent.md:76, 141` and `tool-text-out-of-core.md:29` must agree with each other again.

## C. Missing boundary checks (real bugs)

### C1. The working folder is not checked when a session starts

- **Where:** `lib/helyx/session.ex:76` (`start/2`) and `:110` (`resume/2`)
- **Found by:** three reviewers.
- **Today:** `cwd` is checked only inside `Session.File.create`, and only for valid text, not for a NUL byte.
- **What the user sees with a bad `cwd`:**
  - With a model provider: every turn fails, because the system prompt holds the `cwd`.
  - With Claude Code or Codex: the program starts in a cut, wrong folder, and no error appears. A probe confirmed that `Port.open` cuts `"a\0b"` to `"a"`.
  - `mix helyx` is safe, because it checks `File.dir?/1` first. A client that calls the Session API directly is not safe.
- **Change:**
  - Check `cwd` in `Session.start/2` and `Session.resume/2`: it must be a string, valid UTF-8, and hold no NUL byte. A bad `cwd` returns an error.
  - Delete the `cwd` check in `File.create`.
  - Move its test to the session tests.
  - The NUL check in the bash tool stays (see A7). A tool entry is its own boundary.
- **Doc:** `coding-agent.md:77, 154` become rules of the session.

### C2. The tool specs of plugins enter Core with no check

- **Where:**
  - `lib/helyx/interfaces/tool.ex:53-66` (`by_name/1`, `spec/1`)
  - `lib/helyx/session/hands.ex:154-156`
- **Today:** Core uses the name, description, and parameters of each tool plugin with no check. One bad tool spec is sent with every provider call, so every turn of the session fails.
- **Also today:** `Hands.tools/1` calls `Tool.spec/1` again on each call (`hands.ex:154-156`). So a check in `Tool.by_name/1` checks one value, and a new, unchecked value goes to the provider.
- **Change:**
  - Build each spec once, at session start. Check it, and store that same value.
  - Use the stored value for every provider call, and never call the plugin callbacks again.
  - A bad spec returns `{:error, {:bad_tool_spec, name}}`, and the session does not start.
  - The ticket defines the accepted shape:
    - `name`: a non-empty string, valid UTF-8, unique among the tools
    - `description`: a string, valid UTF-8
    - `parameters`: a map with string keys that passes `Message.encodable?/1`
  - Add one test with a bad test tool, and one test that shows the plugin callbacks run only once.

### C3. Claude Code and Codex do not check that perl exists

- **Where:** `plugins/bundled/lib/helyx/watchdog.ex:231`: `System.find_executable("perl") || "/usr/bin/perl"`
- **Today:** the bash tool checks for perl when the hands start (`bash.ex:50-58`). The harness providers do not check for perl. The fallback path hides the problem, and the user sees `{:task_exit, ...}` and not "perl not found".
- **Change:**
  - Delete the fallback.
  - Check for perl next to the `claude` and `codex` lookup in each `stream/3`, through one `HarnessIO` helper.
  - Add one test for each provider.

## D. Boundary checks that destroy too much

### D1. One bad harness label loses the whole chat (#129 in its real form)

- **Where:** `lib/helyx/session/file.ex:359-361, 372-380`
- **Today:** on resume, a `harness_session` entry with a bad id rejects the whole file, and so does an entry with a missing key. The label is optional: without it, Helyx starts a fresh Claude Code or Codex chat (`transcript.ex:48-57`).
- **Change:**
  - The reader accepts the entry.
  - A bad entry that names its provider removes the label of that provider. If the reader only skips the entry, an older, stale label of the same provider comes back.
  - A bad entry that does not name a usable provider **removes every earlier label**. The reader cannot know which label the entry replaced.
  - Why this matters: `Transcript.resumable/3` resumes a label when the last assistant message came from the same provider after that label began. With an old label, a damaged replacement, and a later message, the old label passes that test. The provider then skips the replay and resumes a chat that never saw the newer messages.
  - The tests at `file_test.exs:102-133` change from "rejected" to "resumes with no harness session for that provider".
  - New test: an old label, a damaged replacement with no provider, and a later assistant message. The resume must give no harness session.
- **Doc:** `coding-agent.md:162` changes.

### D2. One bad optional field on one message loses the whole chat

- **Where:** `lib/helyx/session/file.ex:290-324`, `decode_message/1`
- **Today:** on one message, a `usage` that is not a map, an unknown `stop_reason`, or a `model` that is not a string rejects the whole file. Core does not need any of these fields to resume. The content, the role, `tool_call_id`, and `is_error` are different: they are needed, so their check stays.
- **Change:** decode a bad `usage` as `%{}`, and a bad `model` or `stop_reason` as `nil`. Missing values already decode this way. The tests at `file_test.exs:335, 343, 351` change for these fields.
- **Note:** a comment at `message.ex:103` says that a new stop reason is a change of the file format. If you want to keep that rule, use the file version check for it.

### D3. A `/model` switch to a bad external provider crashes the TUI

- **Where:** `plugins/bundled/lib/helyx/tui.ex:487-490`, `model_error/1`
- **Today:** Core returns `{:bad_provider_turn, id}` (`session.ex:137`). The TUI has no clause for it, so the whole screen dies for one rejected command. Only an external plugin can cause this.
- **Change:** add a clause that shows a notice.

### D4. One broken tool call fails the whole OpenAI turn

- **Where:** `plugins/bundled/lib/helyx/provider/openai.ex:444-446, 462-470`
- **Today:** when one call has arguments that are not valid JSON, the turn fails. The text and every other call are lost, and the model gets no chance to correct the call. The error also holds the raw JSON, which can be up to 10 MiB. Core already handles one bad call in proportion: it gives that call an error result, and the other calls run (`stream.ex:91-95`, `server.ex:483`).
- **Change:**
  - Give the bad call an error tool result, as the rejected-call path does. This needs a small change in Core, because `{:rejected_call, ...}` is private to `Session.Stream`.
  - As a minimum, cut the JSON in the error.
  - Needs a short feature doc.

## E. Checks that a doc or an earlier review requires

### E1. The catch-all `handle_info` of the session server

- **Where:** `lib/helyx/session/server.ex:266-302`
- **Today:** it drops and logs every unknown message. Its comment names two sources, a late reply and a stray monitor message. Neither can reach a live session:
  - a late reply of a call goes to an alias, and the runtime drops it
  - the flush and shutdown calls remove the Task messages
  - race guards handle the stale turn messages
- **Required by:** #95, `coding-agent.md:90`.
- **Options:**
  1. **Delete it (lean).** An unknown message is then a bug and crashes the session. This agrees with A3.
  2. **Keep it**, and correct the comment, which names two sources that cannot happen.

### E2. Settled: keep the whole release check

- **Where:** `plugins/bundled/lib/helyx/watchdog/group.ex:37-48`
- **Today:** the release checks the shape of each handle again. Two sources already guarantee the shape: `parse_marker/2` (`watchdog.ex:323-333`) for the command groups, and `Port.info(port, :os_pid)` (`watchdog.ex:201`) for the watchdog handles.
- **Decision:** keep `group > 1`. If it fails, `kill -- -1` stops every process of your user. Unknown handles stay "still held": they must never disappear from the release result.
- **Change:** a comment only. It names both sources, `parse_marker/2` and `Port.info(port, :os_pid)`, and calls this check one deliberate safety lock.

### E3. The text check on the id of an external tool result

- **Where:** `lib/helyx/session/stream.ex:142`
- **Today:** the session uses the id only to look up an open call (`server.ex:165`). An unknown id is dropped. The raw id never reaches the transcript, an event, or the file.
- **Options:**
  1. **Delete it (lean).** A bad id is then dropped like an unknown id. Today it fails the turn.
  2. Keep it. It is at the boundary and costs one line.

## Process changes (T0, done in c9fec48)

**Why:** the review process creates defensive code today. The failure-path brief in `/ship` asks the agent to probe "input shape" for "every new or changed operation". An agent that calls an inner function with a value that no caller can pass then finds a "bug", and the fix adds a check. The Codex adversarial review works the same way. Nothing in the process says that such a finding is not a finding.

T0 changes only docs and skills. It goes first, so every worker of T1 to T8 already works under the new rules.

### 1. `AGENTS.md`, "Elixir guidelines": one new rule

> - Validate at boundaries. A boundary is where data comes from something this code does not control: client input, plugin output into Core (stream events, tool results, callback returns), the disk, external programs and networks, tool arguments from the model at the tool entry, terminal input, and config. Check there once, and handle the error there. Inner code trusts the check: it has no fallback clause, error return, or repair for a state that no caller can make. A state that only a bug can make crashes ("let it crash"); a pattern match or a guard that crashes is fine.
> - Remove a repeated check only when the earlier check still proves the same property. Keep a documented safety check. Check the new limits that a transformation, an accumulation, or elapsed time introduces (text that expands, a buffer that grows, a deadline that approaches).
> - Use the checked value. If an operation reads a new value, validate that value before use. A prior check of external state does not remove the need to handle a failure when the state is used.
> - Reject the smallest unit that permits safe continuation. Keep unrelated data when its validity is known. State when missing identity, damaged structure, or an unresolved resource requires a larger failure.

The standards axis already checks the `AGENTS.md` rules, so this rule reaches every review with no other change.

### 2. `docs/agents/review-checklist.md`: a new section "Boundaries"

> - Each input is checked at its boundary (see `AGENTS.md`). The spec axis names the boundary of every new input.
> - Inner code has no defensive handling: no fallback clause, `{:error, _}` return, `rescue`, or repair for a state that no caller can make. A reviewer reports such code as a finding, with every caller and the upstream check (`file:line`). A repeated check is a finding only when the earlier check still proves the same property; a documented safety check and a check of a limit that a transformation, an accumulation, or elapsed time introduces are not findings.
> - Later code uses the checked value. A new read of the source is a finding only when its value is used under the earlier check with no check of its own.
> - A boundary check rejects the smallest unit that permits safe continuation. The failure path names what one bad value destroys, and the feature doc states each case where missing identity, damaged structure, or an unresolved resource requires a larger failure.
> - A public plugin entry (a tool's `run/2`, a provider's `stream/3`) is a boundary for all of its arguments, because code outside the hands and the session can call it.

### 3. `.claude/skills/ship/SKILL.md`, the failure-path brief: add two sentences

> Probe through a boundary. A reproduction that calls an inner function directly with a value that no caller can pass is not a finding; name the boundary that lets the value in, or drop the finding. Also report the opposite: a new check, fallback, or repair in inner code that duplicates a boundary check which still proves the same property. A documented safety check is not a duplicate.

### 4. `.claude/skills/orchestrate/SKILL.md`, "Judge every finding yourself": add one sentence

> Reject a finding whose reproduction enters below the boundary with a value no caller can pass; a fix for it would add defensive code. Record the rejection with the boundary that already covers the value.

The invariant sentence for Codex also names the boundaries of the change, so the reviewer knows which checks are the designed ones.

### 5. `docs/features/TEMPLATE.md`, "Bounds": one sentence

> Each row names where the bound is enforced. Explain any additional checks required by transformations, accumulation, elapsed time, or rendering.

### Not changed

`/simplify` is a built-in skill, so this repo cannot change its angles. The standards axis covers the rule through `AGENTS.md`.

## Proposed tickets

| Ticket | Contents | Main files | Blocked by |
|---|---|---|---|
| T0 Boundary rule in the process | The process changes above | `AGENTS.md`, `review-checklist.md`, `ship` and `orchestrate` skills, `TEMPLATE.md` | none |
| T1 Session boundary for `cwd` | C1, A2 | `session.ex`, `session/file.ex` | T0 |
| T6 perl check for the harness providers | C3 | `watchdog.ex`, `harness_io.ex`, `claude_code.ex`, `codex.ex` | T0 |
| T4 The reader keeps the chat (replaces the body of #129) | D1, D2 | `session/file.ex`, `transcript.ex` | T1 |
| T5 Check the tool specs once, and store them | C2 | `tool.ex`, `hands.ex`, `server.ex` | T1 |
| T2 Delete inner defensive code | A1, A3 to A6, E1, E2 (comment), E3 | `message.ex`, `server.ex`, `stream.ex`, `view_model.ex`, `tui.ex`, `codex.ex`, `group.ex` | T4, T5, T6 |
| T3 Text repair at the boundaries | B | `stream.ex`, `message.ex`, `tui.ex` | T2 |
| T7 TUI handles `:bad_provider_turn` | D3 | `tui.ex` | T3 (both edit `tui.ex`) |
| T8 One bad OpenAI tool call | D4. Needs a feature doc first, so `ready-for-human` | `openai.ex`, `stream.ex` | T0 |

T0 is docs only, and it goes in first, directly, with no worker. The first wave of workers is T1 and T6. They share no file. Two workers run at a time.
