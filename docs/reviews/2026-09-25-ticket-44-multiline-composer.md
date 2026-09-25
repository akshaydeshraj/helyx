# Review: multiline composer (#44)

Scope: `plugins/bundled/lib/helyx/tui.ex`, its tests, `docs/features/multiline-composer.md`, and `docs/features/coding-agent.md`. Base `efd5d9f`.

Bounds sensor, round 1: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

## Round 1 (full)

Simplify: a comment line was joined to 116 columns (wrapped). The Enter exclusion moved from the widget helper to the `handle_event` clause. Skipped: one wrapper that settles after every state change (only `edit/3` and the `/model` switch change the composer height, and both settle), a count of new lines without a list, a shorter read on Backspace, and a shared `line_count/1` with `Helyx.Tool.Read` (the two rules differ on the empty text).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Standards | No test one under each limit: 4 pasted lines, 7 composer lines. No multibyte line count | Fixed: tests for 4 and 5 lines, 7 and 8 lines, and a paste of wide and multibyte characters at 5 and 6 lines |
| 2 | Standards | A comment line of 127 columns above `command/1` | Fixed |
| 3 | Standards | `key/2` shares its name with the `key` variable | Fixed: renamed `widget_key/2` |
| 4 | Standards | The Enter exclusion is an `if` condition, not a clause | Fixed: one `handle_event` clause for the repeat and the release of Enter |
| 5 | Standards | Data clump `input` and `pastes`; feature envy in the Backspace clause; two helper styles in the test file | Judgement calls. The Backspace clause now says why it drives the widget key by key. No other change |
| 6 | Spec | "Backspace on the marker removes the whole paste": only a Backspace right after the marker did | Fixed: a Backspace with the cursor inside a marker or right after it removes the whole marker. Test added |
| 7 | Spec | The Tab key now indents, which the doc did not say | Fixed in the doc; test added |
| 8 | Spec, failure path | Text equal to a pending marker, typed or in a short paste, is replaced by the paste on send, and one Backspace removes it (reproduced) | Accepted hole, stated in the feature doc. The marker is plain text in the widget; a structural fix needs marker positions that the widget does not report |
| 9 | Failure path | A marker changed by one character sends the changed text, and the paste is lost with no notice (reproduced) | Accepted hole, stated in the feature doc |
| 10 | Spec | Control characters other than tab and LF drop from a paste | Kept: the one-line input dropped them too, and the doc states it |
| 11 | Spec | The kitty keyboard protocol is not on | Undecided: ExRatatui 0.14.1 has no call for keyboard enhancement flags. Needs a fork or an upstream change |

## Round 2 (full)

The round 1 fix changed about 40 code lines in one file and renamed a function, so this round was full. Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

Simplify: the Enter clause for the repeat and the release moved under the press clause, with no guard. Kept: the `map_size(pastes) > 0` guard on the Backspace clause (it skips a read of the composer when no paste is pending). Skipped: Delete on a marker (scope; the doc states it).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Standards | The default `{0, 1}` in `widget_key/2` has no name | Fixed: a comment names the two counts |
| 2 | Standards | No devlog for the session | Fixed: `docs/devlogs/2026-09-25-ticket-44-multiline-composer.md` |
| 3 | Standards | The moduledoc repeats the limits 8 and 5; two helper styles in the test file | Judgement calls, no change |
| 4 | Spec | No test that the repeat and the release of Enter leave the composer text | Fixed: the assertion is in the rejected-send test |
| 5 | Spec | No test at a two-digit id or a three-digit line count | Fixed: ids #9 to #11, and a 100-line paste |
| 6 | Spec | The doc said the drawn screen and the scroll screen are the same; below 12 rows with a full composer the layout gives 0 rows and the scroll screen is 1 row | Fixed in the doc as a stated exception |
| 7 | Spec | The `pastes` row said "since the composer was last emptied"; a Backspace that empties the composer keeps the map | Fixed in the doc |
| - | Failure path | No finding: 12 probes on the invariant (markers side by side, cursor at a marker start, line ends, multibyte text before a marker, another row, repeat kind) held | - |

## Round 3 (reduced)

The round 2 fix changed one comment line of code; the rest was tests and Markdown. Spec and failure-path agents only. Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Spec | The `/model` row said "the rest of the line" and "a new line after the ref makes an invalid model ref". The code trims the rest of the composer text: a new line is a separator, a final new line is trimmed, text on a later line makes an invalid ref | Fixed in the doc; tests for the three cases |
| 2 | Failure path | Below 12 rows with a full composer, the render gave the transcript 0 rows while `on_screen/2` counted 1 (reproduced) | Fixed in the code: `composer_rows/2` shrinks the composer to keep 1 transcript row down to a height of 5, and both the render and `on_screen/2` read it. Test at 11, 5, and 4 rows |
| 3 | Failure path | Delete or Ctrl+J inside a marker changes it, and the paste is not sent (reproduced) | Accepted hole, stated in the feature doc (round 1 #9). The mechanism, a marker that is plain text, is not patched; making markers atomic is a design question for the user |
| 4 | Failure path | Pasted text equal to a pending marker expands into the paste (reproduced) | Accepted hole, stated in the feature doc (round 1 #8) |

## Round 4 (full)

The round 3 fix added a function, `composer_rows/2`, so this round was full. Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Simplify: clean.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Standards | `composer_rows/1` (the wanted height) and `composer_rows/2` (the drawn height) share a name; the numbers 2 and 3 are bare | Judgement calls, no change. `edit/3` compares the wanted height, so on a small terminal it can run one `settle/1` that changes nothing |
| 2 | Standards | The scrollback row said "3 to 10, and fewer" and "an edit that changes the composer height" | Fixed in the doc: "at most 10, and down to 3", and "the composer line count" |
| 3 | Spec | No test at a height of 6, one over the smallest composer | Fixed: heights 6, 5, and 4 |
| 4 | Spec | The `/model` row said "a final new line is trimmed" and "a line is a command line"; the code trims all whitespace after the ref and reads the start of the whole composer text | Fixed in the doc |
| - | Failure path | No finding: heights 0 to 14 against composer line counts 1 to 9, with scroll keys, edits, pastes, resizes, and sends while scrolled | - |

Round 4 changed tests and Markdown only, so no further round.

## Round 5 (full)

Precommit failed on Credo strict: `widget_key/2` nested too deep. The fix moved the inner search into `on_marker/3`, a new function, so this round was full. Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Simplify: clean.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Standards | `on_marker/3` names no return value; the "a marker is ASCII" note sits on `widget_key/2`, not on the arithmetic that needs it | The note moved to `on_marker/3` with the round 6 fix. The name is a judgement call, kept |
| 2 | Spec | No finding | - |
| 3 | Failure path | One Backspace was quadratic in the cursor line: each match converted its line prefix to count code points. 4,000 copies of a pending marker on one line (100 KB) took 1.19 s, 16,000 took 25.6 s, with the TUI process blocked (reproduced) | Fixed at the mechanism, because this is the second finding on the Backspace marker search (round 1 #6): the cursor column becomes a byte offset in one pass, and the matches compare bytes. The doc row states the linear cost |

## Round 6 (full)

The round 5 fix is the second finding on the Backspace marker search, so this round was full. Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`. Simplify: one comment said "one pass" for a walk of three linear passes; fixed to "a linear walk".

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1 | Standards | `cursor` is a byte offset while the widget cursor is code points; `count` does not say Backspaces; the comment says linear in the line where it is linear for each marker; three calls of `textarea_handle_key` | Judgement calls, no change. The doc row states the cost for each marker |
| - | Spec | No finding. The reproduction: 4,000 copies now 3.8 ms (was 1.19 s), 8,000 copies 9.4 ms | - |
| - | Failure path | No finding. 1,000, 4,000, 16,000 copies: 0, 3, 21 ms (was 71 ms, 1.19 s, 25.6 s). 200 markers with a line of 90,000 multibyte code points: 10 ms. Code point and grapheme cases held | - |

The reviewers changed no code in round 6. No further round.
