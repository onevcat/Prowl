# 090.004 — S3: the mirror's draft confirmation

## Context

With `on_draft` on the wire (S2), the iOS mirror could ask the Host to replace a draft, but
still showed a refusal as a dead-end note.

## Change

- `MirrorSession`: `Submission.onDraft`; `MirrorDeliveryOutcome.hostDraft` (from
  `error.details.input`, `reason: draft` only) and `replacedDraft` (from
  `data.input.replaced_draft`); `hostDraft` while the refusal is shown;
  `replaceHostDraftAndSend()` (resends the same text with `on_draft: replace`),
  `bringHostDraftHere()` (prepends the Mac's text to the phone draft, dismisses the refusal, and
  marks the next send `replace`, only for a complete draft), `dismissHostDraft()`.
  `MirrorHostDraft` carries text, completeness, replaceability and recovery.
- `ComposerBar`: the refusal becomes a card (`composer-draft-card`) with the draft's excerpt,
  **Replace and Send** (`mirror-replace-draft`, only when replaceable), **Bring Draft Here**
  (`mirror-bring-draft`, only when complete) and **Cancel** (`mirror-dismiss-draft`). An accepted
  message that replaced a draft shows a quiet note with the recovery (`⌃S there brings it back`)
  until the next draft is typed.
- `MirrorUIFixture`: `--mirror-ui-refuse-input-draft` refuses with the draft details and
  accepts a `replace` resend with `replaced_draft`.
- Tests: `MirrorCommandTransportTests` (refusal details, Replace resend policy, Bring Here merge,
  incomplete drafts), UI test `testDraftOnTheMacOffersReplaceAndBringHere`.
- Docs: `docs/remote-mirror.md`.

## Refs

PR (S3), docs-ai 090 plan.
