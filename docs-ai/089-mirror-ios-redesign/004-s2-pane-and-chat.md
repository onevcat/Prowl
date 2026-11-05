# 089.004 — S2: Pane and Chat

## Context

S2 restyles the pane screen and the chat. In the 088 chat every tool call was its own card.
On an active agent the cards filled the screen and pushed the agent's words out of view.
onevcat asked for consecutive tool calls to merge into a count, with the expanded state
kept quiet and in secondary type (2026-11-06).

## Change

| Area | Change |
| --- | --- |
| Pane chrome | `PaneHeader` and the Chat \| Screen picker are gone. The principal toolbar item `PaneTitle` shows the pane name and, under it, the Mac state (`MirrorStateLabel`) and project / worktree. One toolbar button (`pane-mode`) switches Chat (`text.bubble`) and Terminal (`apple.terminal`). A lost connection shows `MirrorPaneConnectionBanner` (reason in red, Reconnect or Take Over) under the toolbar. A blocked agent shows `MirrorBlockedStrip` above the composer, in place of inline attention rows. |
| Chat rows | `MirrorChatRow.rows(_:)` folds every run of tool and reasoning items between two other items into one `.steps` row. It drops attention items and runs that have only reasoning. `Steps` gives the tool count, the failed count (error or non-zero exit), the running tool and the tool kinds. |
| Steps row | Collapsed: up to three kind glyphs, "N tool calls" in footnote secondary, failures in red, or the running call with the Bagua spinner. Expanded: one secondary line per call (glyph, title without the `/bin/zsh -lc` wrapper, exit code, duration or status glyph). A line opens `ToolDetailView` (command or file, changes, output) in a sheet. |
| Messages | User bubbles use the `UserBubble` color, and messages over twelve lines or 700 characters fold behind "Show more". Agent text is full width. Inline code is monospaced without a background. Session, compaction and subagent marks are small captions. A resolved prompt leaves one line. |
| Composer | `ComposerBar` is a floating glass field with a round send button inside. The note line shows only for non-accepted receipts, a pane that takes no messages, or a working agent. |
| Latest | The jump-to-latest button is a round glass arrow in a bottom inset, so it sits above the floating composer. |

Tests: `MirrorChatRowsTests` (folding, failure and running counts, attention and lone
reasoning, the fixture conversation keeps every message, shell wrappers). The UI tests switch
modes through `pane-mode` and open steps rows and tool details.

## Decisions

- The copy is "N tool calls", not the reference app's "N other steps". Reasoning folds into
  the same row and never makes a row of its own.
- Attention is not a chat row any more. It was placed by event order and could appear
  above the session start. The pane shows it once, above the composer, until S4 replaces it
  with the prompt panel.

- No title menu for jumping between panes. It would copy the reference app's "title ⌄"
  pattern, and the Agents screen is one Back away. The plan text is corrected.

## Refs

PR (S2).
