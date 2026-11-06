# 089.006 — S4: Answer Prompts from the Phone

## Context

Without this slice the phone could not unblock an agent. Claude Code 2.1.318 also writes no
transcript record while a prompt waits (D6), so the chat could not even show the question.
087 planned `promptRespond` with "verified keystrokes" (087 plan, Design).

## Change

| Area | Change |
| --- | --- |
| Screen menu | `MirrorScreenPrompt` (`App/Sources/Features/RemoteMirror/Conversation/MirrorScreenPrompt.swift`) parses the menu at the bottom of the screen. A dialog footer ("Enter to select", "Esc to cancel", "Press enter to confirm") anchors it. Above the footer: numbered rows, the highlighted one marked `❯` or `›`, numbered 1…n without gaps, and option descriptions. The question is the prose line above. Claude's `│ …` quote, or Codex's `$ command` block (one or more lines), is the detail. "Type something." and "Chat about this" are freeform rows. The content id is `screen:` plus an FNV-1a hash of the question, the detail, the labels and their descriptions, so moving the highlight keeps it. |
| Feed | While the pane is blocked, `MirrorHost.observeScreenPrompt` reads `activeText` at most every 0.5 s and calls `MirrorConversationFeed.observeScreen`. That emits `prompt.opened` with the wire id `<content id>.<occurrence>` (source `screen`, choices = answer rows), and resolves it when the menu changes or goes. A new log segment restates an open screen prompt. A phone answer resolves the prompt at once (`noteScreenAnswer`); the answered menu is ignored for 3 s while it leaves the screen. |
| Command | `promptRespond {pane, prompt, choice}` behind the capability `prompt-respond`. `MirrorHost` answers it itself, never through the CLI router. `MirrorHost` answers only the feed's open wire id. `GhosttyMirrorPaneSource.answerPrompt` checks the following before every key: `isLive` (the connection's lease, and the open prompt), the blocked state, `MirrorKeyGuard` (IME text, and editing after its own last key), and the prompt's content id on screen. It sends one `down`/`up` and waits for the highlight to move exactly one row (up to about 1 s), and repeats. Then `enter`. It never replays. Error codes are listed in `docs/remote-mirror-wire.md`. |
| iOS | `MirrorPromptPanel` above the composer: "Blocked · Question/Permission", the question, the detail in monospaced text, numbered answer buttons with descriptions, a note for typed answers, sending/sent/refused states (`MirrorSession.answerPrompt`, `promptAnswer`). Open prompts leave the chat rows. Each resolved screen prompt leaves one line. It absorbs one transcript copy with the same question. A screen prompt's answer moves to where it happened. |

Tests:

- `MirrorScreenPromptTests` covers the real Claude 2.1.318 question and permission captures (`App/Tests/Fixtures/MirrorScreenPrompt/`), the Codex 0.146.1 approval fixture, the identity, prose and broken menus, and navigation.
- `blockedScreenMenuOpensAndResolvesAPrompt` and `feedResolvesAPhoneAnswerWithItsOutcome` cover the Host and the feed.
- The iOS chat-row and store tests cover open/answered prompts.

Review round 1 fixes:

- S4-R1: the identity covers the detail and the descriptions, and each opening gets its own id.
- S4-R2: authority loss stops the next key.
- S4-R3: editing between keys stops the answer.
- S4-R4: decisions with the same title all stay.

Round 2 fixes:

- S4-R4: a screen answer absorbs a transcript copy only between the same two messages.
- S4-R5: a Codex `$ command` block over several lines is the detail. A command with no question above it does not parse.

Their tests are `aScreenAnswerAbsorbsOnlyTheCopyNextToIt` and `codexMultilineCommandIsTheDetail`.

Round 3 fix (S4-R5): blank lines may be part of the command block, and the parser looks at most 40 lines above the options. A Codex command approval whose command it cannot read in full does not parse. A menu is a Codex command approval when its options have Codex key hints such as `(y)` or `(esc)`, or when Codex's question is above it. The `$ ` block is searched only for those menus, so a shell line in Claude's scrollback is never taken for a command. Tests: `codexApprovalWithoutTheWholeCommandFailsClosed` and `claudePermissionIgnoresShellLinesAbove`.

Round 3 fix (S5-R4, prompt part): the Host runs one command per connection, so a second command closes the connection. `MirrorSession.isDeliveringMessage` is true while a message is pending, and during that time the client refuses to send a prompt answer. The panel says to wait. Test: `promptAnswersWaitWhileAMessageIsBeingDelivered`.

Round 4 fixes:

- S4-R6: the command detail drops only the common left margin and keeps the script's own indentation. So two commands that differ only in indentation get different ids.
- S5-R4: an `unknown` delivery outcome also holds answers, until a receipt or "I've Checked".

Tests: `codexCommandKeepsItsIndentation` and `promptAnswersWaitWhileADeliveryIsUnknown`.

The round 1 tests are `theIdentityCoversTheCommandAndTheDescriptions`, `theKeyGuardAllowsItsOwnKeysButNotLocalEditing`, `feedGivesEveryOpeningItsOwnID`, `takeoverStopsAnAnswerBetweenKeys` and `sameTitledDecisionsAllStayAndOnlyTheirCopiesFold`.

## Decisions

- **Screen first, not hooks.** The screen is what the keys must match. It works for agents started by hand, and it moves no tool input across the hook bridge. Claude's `PermissionRequest` hook payload stays as it is.
- **Arrow keys, not digits.** Each step is verified on screen, and Enter goes only on the verified row. Digit shortcuts differ per agent and version.
- **No typed answers from the phone yet.** "Type something." needs a text field inside the dialog. The panel says to use the Mac.

## Refs

#1050 (S4).
