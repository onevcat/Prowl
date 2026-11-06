# 089 follow-up — Shell commands from the phone

## Context

Shell panes were read-only on iOS: the Host refused the structured `send` because it could
not prove that the prompt line was empty, and an old draft would join the phone's command.
The iOS client also refused a shell send whenever `task.status` was not `idle`, but that
status belongs to the whole worktree, so a command in another tab blocked every shell pane.
onevcat wants to run commands from the phone (2026-11-06).

## Decisions

- **Clear the line instead of proving it empty.** Control-E, Control-U clear any draft
  before the text goes in. The draft is not lost: the shell keeps it in its kill ring.
  Refusing when the Mac typed since the last prompt was rejected, because typing and deleting
  a command also counts as typing.
- **Type one-line commands, paste the rest.** zsh pushes bracketed-paste text onto the kill
  ring, which hides the cleared draft from Control-Y (measured on onevcat's zsh with
  oh-my-zsh). Plain bytes keep the draft on top. Text with newlines or tabs is still pasted,
  so its lines do not run one by one and a tab does not complete.
- **The shell must be alone in front.** The pty's foreground process group must be one
  process, a known interactive shell with only option arguments. `vim`, `less`, `ssh`,
  pipelines, scripts and `zsh -c` refuse with the program's name. This replaces the
  worktree-wide `task.status` check on iOS.
- **The cursor must be on a primary prompt's input line** (review R1, R2). The process
  inventory is the same at a continuation prompt (`echo OLD \` + Return: Control-U clears only
  the last line, and the old first line runs with the phone's command) and while a builtin
  `read` waits (the command becomes its answer). Ghostty fork patch 7 adds
  `ghostty_surface_input_state` (`Terminal.cursorIsAtPrimaryPrompt`): false after OSC 133 C
  (command output), at a continuation line with input above it, on the alternate screen, and
  without shell integration. zsh marks the later lines of a multi-line PS1 as continuations too;
  they count as primary because no input is above them. The check runs again after clearing.
- **Paste only with bracketed paste** (review R3). Without mode 2004 (macOS `/bin/bash` 3.2),
  Ghostty sends pasted newlines as Return and tabs stay completion keys, so such text refuses.
- **The Mirror Host runs it, not the CLI router**, like `promptRespond` and `agentKeys`, so it
  can check the foreground job and the editing guard between steps. The CLI router keeps
  refusing a remote `send`.
- **Key bar in shell panes** (`shell-keys`): ⌃C, Tab, arrows and Return work while a program
  runs too. Between keys the pane must still run no agent; an agent that started stops the
  keys, as an agent that exits does for agent panes.

## Known limits

- vi-mode shells may not bind Control-E / Control-U to "end of line" / "kill line".
- Remote panes (084) run `ssh` in front, so they refuse; the key bar still works.
- Shells without Ghostty shell integration (macOS `/bin/bash` 3.2, integration turned off)
  refuse: there is no prompt evidence.
- A multi-line zle buffer (a newline inserted without running) is cleared only on its last
  line; its earlier lines are input above the cursor, so they refuse only when marked as
  continuation lines.

## Implementation

| Part | File |
| --- | --- |
| Foreground and prompt checks | `App/Sources/Features/RemoteMirror/MirrorShellPrompt.swift` |
| Prompt evidence | Ghostty fork patch 7 (`ghostty_surface_input_state`), `GhosttySurfaceBridge.inputState()` |
| Steps and guard | `GhosttyMirrorPaneSource.sendShellLine`, `pressKeys` |
| Command handling, capabilities `shell-send`, `shell-keys` | `MirrorHost.runShellLine` |
| iOS routing, key bar, placeholder | `MirrorInputRoute`, `MirrorSession.keysAvailable`, `ComposerBar` |

Tests: `MirrorShellPromptTests`, `MirrorHostConversationTests.shellSendGoesToTheSourceAndReportsWhatWasSent`,
iOS `MirrorInputRouteTests` and `shellPanesGetKeysFromAHostThatSupportsThem`. The kill-ring
behavior was checked in a pty with onevcat's zsh: after typed input, Control-Y returns the
cleared draft.
