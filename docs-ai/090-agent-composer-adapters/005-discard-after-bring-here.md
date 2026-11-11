# 090.005 — `on_draft: discard` for Bring Draft Here

## Context

A live run on 2026-11-11 (Claude Code 2.1.322, iPhone simulator against a Debug Host) showed a
loop in S3. **Bring Draft Here** merges the Mac's draft into the phone message and sends it
with `on_draft: replace`. For Claude Code, `replace` is the ⌃S stash, and Claude brings a
stashed draft back after the message is sent. The draft was then in the message and in the
input box again, and the next message from the phone was refused for the same draft.

onevcat's decision (2026-11-12): after Bring Draft Here, the Host must not keep the draft.

## Change

- `AgentDraftPolicy.discard` (`on_draft: discard`, `--on-draft discard`): remove the draft so
  that it does not come back, verify the box is empty, then deliver.
- `AgentComposerAdapter.discardPlan(for:)`. The default is the clear plan when that plan has
  no recovery (Codex ⌃U), else `unsupported`. Claude: `.killRow(endKey: "ctrl-e", killKey:
  "ctrl-u")`, only for a draft of one row (`isComplete`).
- `AgentComposerClearPlan.killRow`: `AgentComposerClearing` presses the end key, records its
  own input generation, then presses the kill key in the same main-actor turn. The box is not
  expected to change after the end key, so there is no settle wait between the two.
- `AgentInputRefusalDetails.discardable` (`error.details.input.discardable`): whether
  `discard` would work for this draft. A decoder for older payloads reads it as false.
- iOS: `bringHostDraftHere()` marks the next send `discard` when the refusal says
  `discardable`, else `replace` (a Host from before this change). A receipt for the draft
  that was brought shows no note; a receipt for another draft (typed on the Mac in between)
  shows the usual "cleared" note with its text.

## Verified facts (Claude Code 2.1.322)

- ⌃U removes only the text before the cursor. With the cursor in the middle of `one two
  three four`, one ⌃U left `e four`, and a second ⌃U changed nothing.
- ⌃E then ⌃U empties a draft of one row from any cursor position.
- The removed text stays in Claude's kill ring: ⌃Y brings it back.
- Not verified: a draft of several rows, a collapsed paste, an image. All stay `unsupported`
  for `discard`.

## Tests

`AgentComposerClearingTests` (kill row, kill row that leaves the draft),
`AgentComposerAdapterTests` (discard plans, refusal details), `DispatchWireModelTests`,
`AgentsCommandParsingTests`, iOS `MirrorCommandTransportTests` (discard after Bring Draft
Here, another draft in its place, older Host). Live: `agents dispatch --on-draft discard` with
the cursor in the middle of the draft; Bring Draft Here from the phone, then a plain message
that is no longer refused.

## Refs

docs-ai 090 plan, [004](004-s3-mirror-confirmation.md); `docs/remote-mirror.md`,
`docs/remote-mirror-wire.md`, `docs/components/cli.md`.
