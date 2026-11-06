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
- **The Mirror Host runs it, not the CLI router**, like `promptRespond` and `agentKeys`, so it
  can check the foreground job and the editing guard between steps. The CLI router keeps
  refusing a remote `send`.
- **Key bar in shell panes** (`shell-keys`): ⌃C, Tab, arrows and Return work while a program
  runs too. Between keys the pane must still run no agent; an agent that started stops the
  keys, as an agent that exits does for agent panes.

## Known limits

- vi-mode shells may not bind Control-E / Control-U to "end of line" / "kill line".
- Remote panes (084) run `ssh` in front, so they refuse; the key bar still works.
- A shell without job control shares its group with its commands; this is not detected
  beyond the one-process rule.

## Implementation

| Part | File |
| --- | --- |
| Foreground check | `App/Sources/Features/RemoteMirror/MirrorShellPrompt.swift` |
| Steps and guard | `GhosttyMirrorPaneSource.sendShellLine`, `pressKeys` |
| Command handling, capabilities `shell-send`, `shell-keys` | `MirrorHost.runShellLine` |
| iOS routing, key bar, placeholder | `MirrorInputRoute`, `MirrorSession.keysAvailable`, `ComposerBar` |

Tests: `MirrorShellPromptTests`, `MirrorHostConversationTests.shellSendGoesToTheSourceAndReportsWhatWasSent`,
iOS `MirrorInputRouteTests` and `shellPanesGetKeysFromAHostThatSupportsThem`. The kill-ring
behavior was checked in a pty with onevcat's zsh: after typed input, Control-Y returns the
cleared draft.
