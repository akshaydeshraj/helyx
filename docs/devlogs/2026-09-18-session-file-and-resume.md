# Session file and resume (#6)

## What was done

- `Helyx.SessionFile`: the append-only JSONL session file from ADR 0001. Header with version, cwd, and model; message and model_change entries; ids with parent links; torn-last-line repair on open; resume of the most recently started session for a working directory, with the current model folded from model_change entries.
- `Helyx.Session`: an optional `:sessions_dir` start option turns persistence on; every completed message is appended through one `append_message/2` helper. `Session.resume/2` restores the transcript and model and starts the session under its old id. `init/1` answers every open tool call with an `aborted` error result, one `open_calls/1` mechanism shared with abort.
- `Helyx.Id`: the one id scheme for sessions, turns, and file entries.
- The test provider gained a `transcript` model that echoes the context, so resume tests can assert the provider sees the same context after a restart.

## What broke

- The first "simplified" torn-line truncation condition missed a torn tail without a trailing newline; the torn-line test caught it, and the two-part condition came back.
- The review found five raise paths in `resume/2` on malformed entries, a file-descriptor leak in `read_header/1`, `:enametoolong` on slugs of long cwds, a session crash on disk failure mid-append, and a session crash on an invalid UTF-8 prompt. All fixed: reader errors are tuples behind a rescue, `File.open/3` fun form closes the handle, the slug keeps its last 100 characters, a failed append logs and turns persistence off, and `prompt/2` validates UTF-8 at the boundary. Text is scrubbed with `String.replace_invalid/1` on write because tool output can carry raw bytes.
- Later review rounds closed the same invariants at more paths: `create/4` returns `{:error, {:create_failed, message}}` instead of raising on any failure (an unwritable existing directory, a non-UTF-8 cwd reaching `JSON.encode!`); a bad line mid-file rejects the file instead of silently truncating good entries after it; a repair that cannot write is `{:repair_failed, posix}`; a non-string model in the file is `{:invalid_file, _}`; invalid UTF-8 provider deltas fail the turn as `{:bad_stream_event, _}` before they reach the transcript. The scrub moved from the file writer into `Message.tool_result/2`, so every consumer of the transcript sees valid text.

## What is next

- #12 wires `append_model_change/2` to a `Session.set_model` API.
- #9 (TUI) passes the real `~/.helyx/sessions` directory; nothing defaults to it yet.
- Known holes, recorded in the feature doc: a failed start after file creation can leave a header-only session; resume reads the whole file into memory.
