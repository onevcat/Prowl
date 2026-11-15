# 093.002 — Toolbar Symbols as Cached Images

## Context

After #1117, the window toolbar still resolved each SF Symbol through the asset catalog about
four times per worktree switch. CoreUI matches the locale for each lookup. The trigger is the
window environment update when the first responder moves to the new terminal (see the plan's
decisions), so wrapping the toolbar content did not help.

A build with every target at `-O` showed the same cost: Prowl code is no longer the main
part of a switch. The build uses the Debug configuration, so the isolation of
`PROWL_DEBUG_DATA_DIRECTORY` stays; `IssueReporting` must stay at `-Onone`, because
swift-frontend 6.4.2 crashes on its `DEBUG` code at `-O`.

| Measurement (16 worktrees, macOS 27.0.1) | Default view | Shelf |
| --- | ---: | ---: |
| Main-thread wait, `-O` (Debug) | 154 ms (150) | 163 ms (167) |
| Named-image resolution per switch, `-O` | 14.6 ms | 14.9 ms |
| Hitches per switch, median (Animation Hitches, 30 switches) | 0.5 | 0 |
| Longest hitch | 200 ms | 16.7 ms |

The Shelf book animation does not drop frames. The CLI wait includes the asynchronous
passes after the switch (`filesChanged` at about +90 ms, the code host status later), so it
is longer than the delay before the first frame.

## Change

`ToolbarSymbolImage` (`App/Sources/Support/ToolbarSymbolImage.swift`) caches
`NSImage(systemSymbolName:)` with a `SymbolConfiguration`. The toolbar symbols use it: Agents,
quick launch fallback, notifications, run and stop, custom commands and their overflow, the
**Add** item, the open-in menu and its open-action symbol, and the time of day in the status
item. An `NSImage` does not follow the SwiftUI font, so each site gives the text style, weight,
and scale that SwiftUI used; the values were calibrated against window screenshots of the base
build:

- toolbar controls: `.body`, `.large`;
- Agents: `.title3`, `.medium` weight, `.large`;
- time of day: `.callout`, `.medium`;
- open-in chevron: `.body`, `.medium`. The `.caption2` font on that label had no effect,
  because the toolbar draws a menu label at its own size.

After the change, only `sidebar.leading` (the system sidebar button) is still resolved. Two
alternating blocks of six rounds: a switch takes 120–122 / 145–146 instead of 131 / 156
(CPU ms / main-thread wait ms), activation 124 instead of 140 ms CPU.

Window screenshots differ from the base build only in the clock, the terminal login time,
the translucent background, and a hover highlight under the pointer. SwiftUI sizes a symbol
in half points and `NSImage` in whole points, so a symbol can differ by one pixel at 2x.

## Not changed

Merging the two `setSidebarSelectedWorktreeIDs` actions that `SidebarView` sends after a
selection: they come from its local `sidebarSelections` copy of the store selection, change no
store state, and cost only one sidebar pass, which #1117 made cheap. Removing the copy means
changing the sidebar selection model for folders, Canvas, and multiple selection.

## Refs

PR #1118
