# 095.015 — Notification content with Show Details

## Context

With **Show Details** on, a notification showed the tab and worktree name, but its text was
always "An agent needs your attention" or "An agent finished". The user could not tell from the
notification whether to act now.

## Change

- The Host fills the encrypted body with what the agent asks or replied
  (`App/Sources/Features/RemoteMirror/Push/MirrorPushSummary.swift`):
  - **blocked**: the question on the agent's screen (`MirrorScreenPrompt.parse`, the same parser
    as Chat) and the first line of its detail, such as the command a permission asks about:
    "Do you want to proceed? · rm -rf build".
  - **done**: the start of the agent's last reply, from the last 256 KB of its transcript
    (`turn.completed` `lastMessage`, else the last `assistant.message`), read off the main actor
    when the turn finishes.
  - One line, code and emphasis marks and heading marks removed, at most 180 characters.
- Without a summary (no menu on screen, no transcript), the body stays the generic text.
- `MirrorPushSender` reads the details before it checks its gates, so a change while the
  transcript is read still stops the push. A body that would make `sealed` longer than the
  gateway accepts (`MirrorPushContract.maximumSealedLength`, 3,000, now in the shared contract
  and tested by the Host and the gateway) falls back to the generic text.
- The phone is unchanged: without Show Details it shows the generic text by kind and ignores the
  body. The Show Details description now says what it adds.
- Tests: `MirrorPushSummaryTests` (screen fixtures, the Claude conversation fixture, the one-line
  form, the size fallback); the contract test for the limit. User docs: `docs/remote-mirror.md`.

## Refs

PR: see the PR that adds this file.
