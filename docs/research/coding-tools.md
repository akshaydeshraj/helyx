# Coding tools in pi, opencode, and codex

Research ticket: issue #17. It was done for ticket #3 (hands and the four tools), and later tickets cite it under #17. Facts gathered on 2026-09-17 from the source of `earendil-works/pi` (`main` at `a8b3dd1`), `anomalyco/opencode` (`dev` at `5a83358`, the repository formerly named `sst/opencode`), and `openai/codex` (`c11fdc9`, `codex-rs/`). The pi and opencode revisions are the branch heads at the time of the research, found afterwards from the commit dates; the research read the branches and did not record a revision. Numbers are from the source, not from documentation.

## Summary table

| | pi | opencode | codex |
|---|---|---|---|
| Default tools | read, bash, edit, write | bash, read, glob, grep, edit, write, task, webfetch, todowrite, websearch, skill, apply_patch, and more | exec_command, write_stdin, apply_patch, view_image, update_plan, web_search, MCP |
| Read tool | yes, no line numbers | yes, `N: line` numbering | none; the model uses `cat`, `sed -n`, `rg` through the shell |
| Read limit | 2000 lines or 50 KB, head kept | 2000 lines or 50 KB, 2000 chars per line, head kept | shell limits apply |
| Read continuation | `[Showing lines A-B of N. Use offset=B+1 to continue.]` | `(Showing lines A-B of T. Use offset=B+1 to continue.)` | none |
| Bash limit | 2000 lines or 50 KB, tail kept, full output spilled to a temp file | 2000 lines or 50 KB, tail kept, full output spilled to a file kept 7 days | 512 KiB head plus 512 KiB tail, middle dropped, then a 10000 token budget with middle truncation |
| Bash timeout | none by default | 2 minutes default, no max | 10 s one-shot; with unified exec the call yields after 10 s and the process keeps running |
| Exit code | non-zero throws, result is an error | in metadata only, not in the text | `Exit code: N` line in the text |
| Process group | `detached: true`, SIGKILL to the group, no grace | `detached: true`, SIGTERM to the group, SIGKILL after 3 s | `setsid`, SIGTERM to the group, SIGKILL after 50 ms; timeout is SIGKILL at once |
| Sandbox | none | none, permission prompts per command | seatbelt on macOS, bubblewrap or Landlock on Linux |
| Edit tool | `edits: [{oldText, newText}]`, several per call | `oldString`, `newString`, `replaceAll` | `apply_patch`, a freeform patch language |
| Edit matching | exact, then one fuzzy pass: NFKC, trailing whitespace, smart quotes, Unicode dashes and spaces | exact, then eight fallback replacers in order | exact, then trailing whitespace, then both sides trimmed, then Unicode punctuation |
| Zero or many matches | error with the count; text must be unique | error; `replaceAll` for many | whole patch rejected before any write |
| Read before edit | not required | not required; a mtime check existed and was deleted in 2026-04 | not applicable |
| Write | `mkdir -p`, overwrite, `Successfully wrote to <path>` | creates dirs, overwrite, `Wrote file successfully.` plus LSP diagnostics | `*** Add File:` in a patch |
| Result shape | `{content: [text or image], details, isError}` | `{title, metadata, output}`, errors as a separate part | function call output text with exit code and wall time |
| Result truncation | inside each tool only | `Truncate.output` on every tool, 2000 lines or 50 KB, head kept | per shell call |

## pi

Source: `packages/coding-agent/src/core/tools/`.

- `createCodingTools` returns `[read, bash, edit, write]`. Tools run in parallel by default; tool result messages are emitted in the assistant's call order even when execution finishes in another order.
- **read**: `path`, `offset` (1-indexed), `limit`. Paths accept `~`, `@` prefix, `file://`, and relative to the session cwd. `truncateHead` keeps whole lines. A first line over 50 KB gets a hint to use `sed -n 'Np' | head -c 51200`. Images are detected by magic bytes, resized to 2000 by 2000 and 4.5 MB, and returned as an image block. Other binary files are decoded as UTF-8 with no check.
- **bash**: `command`, `timeout` in seconds with no default. `/bin/bash -c`, else `bash` on PATH, else `sh -c`. stdin ignored. Env adds `PI_SESSION_ID`, `PI_SESSION_FILE`, `PI_PROVIDER`, `PI_MODEL`, `PI_REASONING_LEVEL`. stdout and stderr interleave into one tail buffer with a rolling 2x window; over the limit the raw stream goes to `pi-bash-<hex>.log` in the temp dir and the footer names it. Non-zero exit throws `Command exited with code N` after the output. Signal death maps to `128 + signal`. Empty output is `(no output)`. Streaming updates are throttled to 100 ms.
- **edit**: `path`, `edits: [{oldText, newText}]`. BOM stripped and restored, CRLF and CR normalised to LF and restored. Exact `indexOf` first, then one fuzzy pass; leading indentation is never normalised. Fuzzy edits rewrite only touched lines. Errors: empty `oldText`, `Could not find the exact text in <path>...`, `Found N occurrences of the text in <path>. The text must be unique...`, overlapping edits, no change. Result text `Successfully replaced N block(s) in <path>.`; the diff goes to the TUI in `details`, not to the model. Writes to one path are serialised.
- **write**: `path`, `content`. `mkdir -p`, then write. `Successfully wrote to <path>`.
- Errors: a throw inside `execute` becomes `{content: [{type: "text", text: message}], isError: true}`. Schema validation failure returns an error result with the errors and the received arguments. Abort of read, edit, or write rejects with `Operation aborted`.

## opencode

Source: `packages/opencode/src/tool/`.

- Every tool's output passes through `Truncate.output` unless the tool set `metadata.truncated` itself: 2000 lines or 50 KB, head kept, full text saved under the data dir for 7 days, with a note telling the model to use grep or read with offset. For `gpt-*` models, `apply_patch` replaces `edit` and `write`.
- **read**: `filePath`, `offset`, `limit` (default 2000). Lines over 2000 chars are cut with `... (line truncated to 2000 chars)`. Output wraps the numbered lines in `<path>`, `<type>`, `<content>` tags and ends with one of three notes: capped at 50 KB, showing A to B of T, or end of file. Directories list sorted entries with a `/` suffix. A missing file lists up to three `Did you mean` candidates. Images and PDFs return an attachment. Binary detection by extension list, then by sample: any NUL byte or over 30 percent non-printable.
- **bash**: `command`, `timeout` in ms (default 120000, no max), `workdir`. Shell from config, then `$SHELL`, then `/bin/zsh` on macOS, else `bash`, else `/bin/sh`; `fish` and `nu` refused. `detached: true`. Abort and timeout send SIGTERM to the group and SIGKILL after 3 s. Merged stdout and stderr, tail kept, spilled to a file over the limit. Exit code only in metadata. Timeout appends a `<shell_metadata>` note; abort appends `User aborted the command`. Each sub-command is parsed with tree-sitter into a permission pattern; file commands with paths outside the project prompt for `external_directory`.
- **edit**: `filePath`, `oldString`, `newString`, `replaceAll`. Line endings normalised both ways, BOM kept. Empty `oldString` creates a file. Replacers in order: exact; per-line trimmed; block anchor (first and last line trimmed, size within 25 percent, middle lines Levenshtein at least 0.65); whitespace collapsed; common indent removed; escapes unescaped; trimmed boundary; context-aware (anchors plus at least 50 percent of middle lines equal); all exact occurrences. A fuzzy match whose span is at least `max(oldLines + 3, oldLines * 2)` lines or over `max(len + 500, len * 4)` chars is refused. Zero matches and multiple matches without `replaceAll` are errors with fixed text. Output `Edit applied successfully.` plus LSP diagnostics; the unified diff goes in metadata.
- **write**: `content`, `filePath`. Creates parent directories, overwrites without checks. Permission prompt shows a unified diff. Output `Wrote file successfully.` plus diagnostics for this file and up to five others.
- The `FileTime` module that made edit and write fail with `You must read file X before overwriting it` was deleted in commit `76a1410` on 2026-04-17. Only a per-file lock remains.

## codex

Source: `codex-rs/`.

- No read, edit, or write tools. The prompt says to prefer `rg` for search and not to re-read a file after `apply_patch` because the call fails if it did not work.
- **exec_command**: `cmd`, `workdir`, `tty`, `yield_time_ms` (10000 default, 250 to 30000), `max_output_tokens` (10000 default), `shell`, `login`, `sandbox_permissions`, `justification`. A command that outlives the yield time returns a session id and keeps running; `write_stdin` writes to it or polls. Up to 64 live sessions. One-shot mode uses `timeout_ms` (10000 default); timeout is exit code 124 with `command timed out after N milliseconds` prepended. Capture is a head and tail buffer of 512 KiB each with `... N bytes omitted ...` between; the model then gets a token budget with middle truncation, marker `…N tokens truncated…`, and a `Warning: truncated output (original token count: N)` prefix. Env is inherited, then `NO_COLOR=1`, `TERM=dumb`, `LANG=C.UTF-8`, pagers set to `cat`, `CODEX_CI=1`, `CODEX_SESSION_ID`. Child calls `setsid`; Linux sets `PR_SET_PDEATHSIG`. Cancel is SIGTERM to the group, 50 ms, then SIGKILL. Sandbox: seatbelt on macOS, bubblewrap or Landlock plus seccomp on Linux, with read-only, workspace-write, and full-access policies.
- **apply_patch**: a freeform tool with a Lark grammar: `*** Begin Patch`, `*** Add File:`, `*** Delete File:`, `*** Update File:` with optional `*** Move to:`, `@@` context lines, `+`, `-`, and space lines, `*** End of File`, `*** End Patch`. The heredoc form inside a shell command is recognised and routed to the same code. Matching passes: exact, trailing whitespace trimmed, both sides trimmed, Unicode punctuation normalised, mirroring `git apply`. The whole patch is verified before any write; failure text is `Failed to find expected lines in <path>:` with the lines. Success text lists `A`, `M`, `D` per file. The result goes through the shell formatter, so the model sees `Exit code: 0`, `Wall time`, `Output:`.
- Result shape for every tool is text: `Wall time`, `Process exited with code N` or `Process running with session ID N`, `Original token count` when truncated, then `Output:`.

## What this means for ticket #3

These are observations, not decisions. The ticket and the feature doc hold the decisions.

- All three keep the head for reads and the tail for shell output. The ticket already says this. 2000 lines or 50 KB is the shared number in pi and opencode.
- Both pi and opencode spill full shell output to a file and name it in the footer. The ticket does not ask for this. It costs one temp file per truncated call and gives the model a way back to the data.
- pi and codex verify an edit against the original text and refuse on ambiguity. opencode adds eight fuzzy replacers. pi's single fuzzy pass (NFKC, trailing whitespace, smart quotes, Unicode dashes and spaces) is the smallest set that handles what models actually get wrong.
- None of the three requires a read before an edit. opencode tried it and removed it.
- Exit code reporting differs. pi makes non-zero an error result; codex puts the code in the text; opencode hides it in metadata. A model that only sees `is_error` cannot tell exit 1 from a crash unless the code is in the text.
- Process groups: all three use `setsid` or `detached`. Grace before SIGKILL is 0 in pi, 50 ms in codex, 3 s in opencode. The feature doc already chose SIGTERM then SIGKILL after a short grace.
- No line numbers in pi's read; `N: line` in opencode. Line numbers cost tokens on every read and help only when the model edits by line, which none of these tools do.
