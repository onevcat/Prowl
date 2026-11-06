# 089 S4 follow-up — Screen prompt fixes from device use

## Context

A device walkthrough on 2026-11-06 (Claude Code 2.1.319) found that iOS could not finish
several AskUserQuestion dialogs:

| Symptom on iOS | Cause |
| --- | --- |
| The first questions of a multi-question dialog showed, then "Blocked · Waiting for your answer on the Mac" | The final "Review your answers / Ready to submit your answers?" page has no footer line. The parser needed a footer, so the page was not a prompt. |
| Every key press on the Mac added one more prompt row | The prompt id hashed every option label. A multi-select box (`[ ]` → `[✔]`) and text typed into "Type something" change the label, so each change resolved the prompt and opened a new one. |
| Multi-select rows were wrong | `[ ] Type something` was not seen as freeform, the unnumbered `Submit` row became the description of the row above, and the phone treated one tap as the final answer. |
| Question titles were cut in two | A multi-question dialog quotes its question with `│`. A wrapped question became a half title plus a half detail. |
| A detail could come from the conversation | The detail search took `│` lines up to 14 rows above the title, also above the dialog's top border. |
| The Terminal view only said "answer on the Mac" | Prompts went only over `conversation-v1`. |

The screens are kept as fixtures: `App/Tests/Fixtures/MirrorScreenPrompt/claude-2.1.319-*.txt`.

## Changes

**Parser (`MirrorScreenPrompt`).**

- A menu with no footer is a prompt only when its question is "Ready to submit your answers?".
  Its detail is the review summary (question and `→` answers).
- Option rows may carry a box: `checked` is nil without one. The unnumbered `Submit` row is a
  row the highlight can reach. Navigation uses the row order (`rows`, `highlighted`,
  `nextKey(toward:)`, `target(after:)`) instead of option numbers.
- "Type something" is known by its place: the last option above the rule before
  "Chat about this". Typed text replaces its label and checks its box.
- The id covers the title, the detail, single or multi select, and the answers with their
  descriptions. It does not cover the highlight, the boxes, or freeform rows. `state` (the
  boxes) changes without a new prompt.
- A `│` question over several lines is one title. The detail search stops at the dialog's
  solid top border.

**Host.** Enter on a multi-select option returns `toggled`; the feed sends `prompt.opened`
again with the same id when `state` changes. The choice `submit` moves to the Submit row and
returns `submitted`, which resolves the prompt. Claude then shows its review page as a new
prompt. A `text-v1` subscription with `includeScreenPrompt` gets `screenPrompt` messages from
the pane's conversation feed, so answers from Terminal are checked the same way.

**Wire.** `Prompt.multiSelect`, `Choice.checked`, the `submit` choice, the subscribe flag
`includeScreenPrompt` and the `screenPrompt` message. All are optional. `text-v1` frames use a
binary encoding, so the prompt cannot ride on them.

**iOS.** A reopened prompt id updates its row in place. The panel shows boxes and a Submit
button for multi-select. Delivered toggles keep the panel open; only a final answer locks it.
The panel shows in Terminal too. `MirrorLog` writes connections, prompts and command results to
the unified log (`com.onevcat.prowl.mirror-ios`).

## Decisions

- **Screen stays the source.** The `PreToolUse` hook has the full question, but no hook fires
  for highlight moves, boxes, tab changes or the review page, and the keys must match the
  screen. A hook could later fill titles and descriptions and be checked against the screen.
  OSC 7501 carries one short `msg`, which Claude writes itself, so it cannot carry a menu.
- **Submit by the Submit row**, which was measured: Enter on it opens the review page. Tab and
  arrow navigation across the tab bar were not measured.

## Tests

`MirrorScreenPromptTests` (review page, multi-select boxes and Submit row, typed freeform row,
identity, quoted title, border), `MirrorHostConversationTests.feedSendsNewBoxesUnderTheSameID`
and `textSubscriptionGetsTheOpenScreenPrompt`, iOS `reopenedScreenPromptUpdatesItsRow`,
`terminalSubscriptionTracksTheScreenPrompt` and `multiSelectBoxesToggleUntilSubmitted`.
