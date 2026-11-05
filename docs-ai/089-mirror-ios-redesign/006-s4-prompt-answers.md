# 089.006 — S4: Answer Prompts from the Phone

## Context

Without this slice the phone could not unblock an agent. Claude Code 2.1.318 also writes no
transcript record while a prompt waits (D6), so the chat could not even show the question.
087 planned `promptRespond` with "verified keystrokes" (087 plan, Design).

## Change

| Area | Change |
| --- | --- |
| Screen menu | `MirrorScreenPrompt` (`App/Sources/Features/RemoteMirror/Conversation/MirrorScreenPrompt.swift`) parses the menu at the bottom of the screen. A dialog footer ("Enter to select", "Esc to cancel", "Press enter to confirm") anchors it. Above the footer: numbered rows, the highlighted one marked `❯` or `›`, numbered 1…n without gaps, and option descriptions. The question is the prose line above. Claude's `│ …` quote, or Codex's `$ command` line, is the detail. "Type something." and "Chat about this" are freeform rows. The id is `screen:` plus an FNV-1a hash of the question and labels, so moving the highlight keeps it. |
| Feed | While the pane is blocked, `MirrorHost.observeScreenPrompt` reads `activeText` at most every 0.5 s and calls `MirrorConversationFeed.observeScreen`. That emits `prompt.opened` (source `screen`, choices = answer rows) and resolves it when the menu changes or goes. A new log segment restates an open screen prompt. The resolution carries the phone's answer (`noteScreenAnswer`). |
| Command | `promptRespond {pane, prompt, choice}` behind the capability `prompt-respond`. `MirrorHost` answers it itself, never through the CLI router. `GhosttyMirrorPaneSource.answerPrompt` refuses unless the agent is blocked, no IME text or local edit is pending, and the screen still shows the prompt id. It sends one `down`/`up` and waits for the highlight to move exactly one row (up to about 1 s), and repeats. Then `enter`. It never replays. Error codes are listed in `docs/remote-mirror-wire.md`. |
| iOS | `MirrorPromptPanel` above the composer: "Blocked · Question/Permission", the question, the detail in monospaced text, numbered answer buttons with descriptions, a note for typed answers, sending/sent/refused states (`MirrorSession.answerPrompt`, `promptAnswer`). Open prompts leave the chat rows. Resolved ones leave one line, deduplicated by question text against the transcript's copy. A screen prompt's answer moves to where it happened. |

Tests:

- `MirrorScreenPromptTests` covers the real Claude 2.1.318 question and permission captures (`App/Tests/Fixtures/MirrorScreenPrompt/`), the Codex 0.146.1 approval fixture, the identity, prose and broken menus, and navigation.
- `blockedScreenMenuOpensAndResolvesAPrompt` and `feedResolvesAPhoneAnswerWithItsOutcome` cover the Host and the feed.
- The iOS chat-row and store tests cover open/answered prompts.

## Decisions

- **Screen first, not hooks.** The screen is what the keys must match. It works for agents started by hand, and it moves no tool input across the hook bridge. Claude's `PermissionRequest` hook payload stays as it is.
- **Arrow keys, not digits.** Each step is verified on screen, and Enter goes only on the verified row. Digit shortcuts differ per agent and version.
- **No typed answers from the phone yet.** "Type something." needs a text field inside the dialog. The panel says to use the Mac.

## Refs

PR (S4).
