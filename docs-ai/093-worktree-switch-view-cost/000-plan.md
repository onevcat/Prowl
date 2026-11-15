# 093 — Worktree Switch View Cost: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-11-15 |
| **Primary PRs** | (fill in) |
| **Related** | [070.002](../070-app-localization/002-resource-lookup-cost.md), [057.003](../057-performance-benchmark-suite/003-interaction-call-path-counts.md), [023-shelf-mode](../023-shelf-mode/000-plan.md) |

## Background

After #1116 removed the string-table parses, a worktree switch still keeps the main thread
busy for about 185 ms in the default view and about 210 ms in Shelf (macOS 27, Debug,
16 worktrees, `prowl list` wait including about 42 ms of fixed CLI cost). The cost grows with
the number of worktrees.

Temporary switches that remove one part of the view tree (`--app-env`, see 057.003) located
the cost. Medians of 18 rounds, CPU ms / main-thread wait ms saved:

| Removed part | Default view | Shelf |
| --- | ---: | ---: |
| Terminal content | 60 / 40 | — |
| `.id(worktree.id)` rebuild of the terminal view | 18 / 22 | none |
| Sidebar | 28 / 28 | 25 / 25 |
| Toolbar | 17 / 16 | 23 / 21 |
| Tab bar | 8 / 12 | — |
| Spines other than the open book | — | 94 / 28 |
| Book-switch animation | — | 67 / 7 |
| Menu bar commands | none | none |

Samples of 30 switches add these causes on the main thread (ms per switch, Debug):

- A view that holds `@Shared` pays for `Shared.init` each time its parent builds it, and
  for `Shared.==` each time SwiftUI compares it: `==` reads `@Dependency(\.snapshots)` and
  both values. About 14 ms in Shelf (one `@Shared` per spine), 6 ms in the default view.
- `RepositorySectionView` reads `state.selection`, and every section gets the full
  selection set, so a switch evaluates every section and every worktree row with its menu.
- Every spine evaluates its body on every book switch.
- `ContentView.body` builds the command palette items on every repositories change, also
  while the palette is closed, and the palette view then sends `updateSelection`.
- `GhosttyRuntime.splitDividerWidth()` reads the config file on each terminal body.
- AppKit recomputes the window drag margins on each animation frame in Shelf (about 20 ms
  per switch), and the toolbar item views lay out again (about 12 ms).

## Goals

- Make a switch evaluate only the views whose content changes, without visible change.
- Keep the cost of a switch independent of the number of repositories.

### Non-goals

- Removing the Shelf book animation or the terminal crossfade (023.004 keeps them).
- Removing `.id(worktree.id)` from the terminal view: it saves about 20 ms in the default view
  only, and moves focus and tab-bar state across worktrees.

## Design / Approach

1. Views that SwiftUI compares often take resolved values instead of `@Shared`:
   `ShelfSpineView` takes its `RepositoryAppearance`; `RepositorySectionView` takes its
   appearance and `RemoteProjectHostSummary` from `SidebarListView`.
2. `ShelfSpineView` and `RepositorySectionView` conform to `@MainActor Equatable` and the
   parents apply `.equatable()`. `==` compares every value that the body reads; it skips the
   actions, which read the store or the terminal state when they run. A view that SwiftUI
   should skip takes no `Binding`: SwiftUI evaluates a view again whenever its parent passes
   a binding, whatever `==` returns.
3. The parent resolves the selection: a section gets `isExpanded`, `isSelected`, the
   selected workspace child, the selected worktrees of its own repository, and the full set
   only during a multiple selection. Row actions that need the full set read it from the
   store when they run.
4. A spine compares its distance from the open book only up to the end of the tint ladder,
   so distant spines stay equal when the open book moves.
5. Each worktree row builds inside `EquatableContent` (`App/Sources/Support/EquatableContent.swift`)
   with a value that holds everything the row reads from `WorktreeRowsView`, so a selection or
   hover change builds only the rows whose value changes.
6. `CommandPaletteOverlayHost` builds the palette items only while the palette is open.
7. `GhosttyRuntime` caches the divider width until the config or its source changes.

## Alternatives & decisions

- Toolbar: the window toolbar resolves the symbol of every item again (about 13 ms per
  switch, all of it in CoreUI) four times per switch. Wrapping each toolbar control in
  `EquatableContent`, moving the sidebar **Add** item out of `SidebarListView`, and moving the
  whole detail toolbar into an `Equatable` host each left the count and the time unchanged.
  The rebuild follows `NSHostingView.updateEnvironment`, which runs when the first responder
  moves to the new terminal. Rejected; all three were reverted.
- Shelf drag margins: during the book animation, the moving hover tracking areas make AppKit
  compute the window drag margins on each frame. Each pass asks the content `NSHostingView`
  for `acceptsFirstResponder`, which walks the focus order of the whole window (about
  17 ms per switch). Removing hover or the animation would remove it; 023 keeps both.
- Moving the open book out of the spine layout: 023 rejected a terminal overlay for edge
  artifacts.
- Splitting the spine into a tinted shell and an `Equatable` content: about 4 ms of spine
  code remains per switch, so the extra structure is not justified yet.

## Amendments
