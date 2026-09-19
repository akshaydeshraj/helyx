# 2026-09-19: model switching mid-session (#12)

## Done

- `Helyx.Session.set_model/2`: parse, provider lookup, then one session call that appends a `model_change` entry, replaces the model ref and the provider module, and emits a `model_change` event with a nil turn id.
- A turn fixes its model and provider when it starts (`Turn.model`, `Turn.provider`), so a switch during a turn takes effect on the next turn, a drained follow-up too.
- `Helyx.ModelRef.parse/1` owns the bounds of a ref: valid UTF-8, at most 256 bytes, no whitespace, no category C character. Start, resume, and switch all go through `resolve_model/2`.
- `persist/2` takes the append as a function, so a failed `model_change` append turns persistence off the same way a failed message append does.
- TUI: `/model provider/model` in the composer. The status bar follows the event, not the call. A rejected ref adds a client notice (`ViewModel.notice/2`) and stays in the composer.
- `SessionFile.append_model_change/2` and the resume side existed from #6; this ticket only calls them.
- The harness half of the last acceptance box waits on #10. The tests switch between two provider modules with different ids, in both directions, at the session seam and at the TUI seam.

## What broke

- Command recognition took three designs. A word split missed U+00A0. A prefix match with `String.trim_leading/1` missed a BOM and a zero width space, and the input widget drops a pasted tab, so `/model<tab>a/b` arrives as `/modela/b`. The third design makes every line that starts with `/model`, after whitespace and category C characters, a command line that is never sent.
- In round 3 the reviewers got an invariant from me that no code can keep: "nothing that looks like the command reaches the model". Homoglyphs and invisible characters outside category C break it for any pattern. The fix was to the claim: the doc states the rule on bytes and its limit, and a test pins the limit.
- The first size estimate for a `model_change` entry, 400 bytes, was wrong: a ref of `"` characters doubles in JSON. Measured at 656.
- A mutant that emits the event twice passed every root test until round 5 added `refute_receive`.

## Next

- #10 and #11: the first harness provider. Then one test that switches from a harness to a model provider and back closes the last box in full.
- A decision, if wanted: a general `/word` command rule in the composer. Not built; one command exists.
