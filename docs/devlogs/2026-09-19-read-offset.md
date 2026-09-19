# 2026-09-19: the read tool rejects a bad offset (#75)

## Done

- `Helyx.Tool.Read` no longer has the catch-all `window/2` clause that turned a bad `offset` into line 1.
- `offset/1` accepts a positive integer, a float with no fraction, and a missing or `null` value. Any other value is an error before the file is read.
- The error names the kind of the value and never shows the value. The longest text is 111 bytes.
- The bounds table in `docs/features/coding-agent.md` has a new row, `read tool offset`.
- The review record is `docs/reviews/2026-09-19-ticket-75-read-offset.md`.

## What broke

- The first error text showed the value through `inspect/2` with `limit` and `printable_limit`. Two review rounds broke its byte bound: `inspect/2` does not limit an integer, and `printable_limit` counts characters for each string. The two-findings rule replaced the mechanism with a constant text for each kind.

## Next

- The ticket names a `limit` argument. The tool has none. A real `limit` needs a line count in `Helyx.Tool.truncate/3`. Ticket pending.
- An offset after the last line gives an empty ok result with no notice. Ticket pending.
- The JSON encode of tool call arguments for the session file is quadratic in the digits of a large integer. Ticket pending.
