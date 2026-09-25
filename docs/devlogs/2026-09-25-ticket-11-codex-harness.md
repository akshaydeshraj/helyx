# Ticket #11: the Codex harness provider

Date: 2026-09-25. Branch `ticket/11-codex-harness`.

## Done

- Research on `codex app-server` (codex-cli 0.155.0) in `docs/research/codex-app-server.md`: the handshake, threads, turns, items, the lost-thread error, `thread/inject_items`, `turn/interrupt`, and the process groups.
- `Helyx.Provider.Codex`: `codex/<model>` refs, one run per turn, resume of the stored thread, a fresh thread on a lost one in the same run, replay of the transcript with `thread/inject_items` under the 400,000-byte cap, tool items as calls and results, allow-all permissions, and deterministic answers to server requests.
- `Helyx.HarnessIO`: the line cap, exit wait, error cut, prompt split, and replay cap moved out of `Helyx.Provider.ClaudeCode`, so both harness providers share them.
- `Helyx.Watchdog`: open input that ends at a NUL byte, and a public `write/2`.
- `Helyx.Hands`: a harness stream Task gets `Task.shutdown/2` with a 2,000 ms grace, so the Codex stream can send `turn/interrupt` before the release.
- Tests use a fake `codex` script on `PATH` that replays the protocol lines. No test uses the network.

## What broke

- The first fake matched the method with `sed` and assumed a JSON key order. Every test hung. The fake now reads the method with perl `JSON::PP`.
- The abort test first waited for `tool_execution_start`, which the session emits only at `message_end`.
- Codex completes tool items out of order and side by side. The session aborts every open call at each `message_end`, so real results were lost. The provider now holds a `message_end`, and the events after it, until the calls of the sent messages have their results. Review rounds 1 to 4 found gaps in this ordering (see `docs/reviews/2026-09-26-issue-11-codex-harness.md`).

## Next

- Codex command groups are not held by Helyx. The watchdog and the release give codex 5,000 ms after the TERM to end them; a codex stuck past that can leave them running (accepted hole, ADR 0004 revision of 2026-09-25, #11).
- An abort or a steer drops the held Codex events, finished results included: the session closes the turn when the abort starts. Keeping them needs a session change (#112).
