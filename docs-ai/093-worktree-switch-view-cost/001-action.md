# 093 — Worktree Switch View Cost: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-15 | Shelf spines, sidebar sections, and worktree rows skip unchanged bodies; palette items only while open; cached divider width | (fill in) |

## Outcome & current state (as of 2026-11-15)

- `App/Sources/Features/Shelf/Views/ShelfSpineView.swift`: `@MainActor Equatable`, takes its
  `RepositoryAppearance`; `ShelfView` applies `.equatable()`.
- `App/Sources/Features/Repositories/Views/RepositorySectionView.swift`: `@MainActor Equatable`,
  takes the resolved selection, expansion, appearance, and host summary, and an
  `onToggleExpanded` action instead of a binding. `SidebarListView` resolves them and applies
  `.equatable()`.
- `App/Sources/Features/Repositories/Views/WorktreeRowsView.swift`: each row builds in
  `EquatableContent` from a `RowInputs` value. The command-click toggle reads the full
  selection from the store; the row menus get the full set only during a multiple selection.
- `App/Sources/Support/EquatableContent.swift`: the generic wrapper.
- `App/Sources/App/ContentView.swift`: `CommandPaletteOverlayHost`.
- `App/Sources/Infrastructure/Ghostty/GhosttyRuntime.swift`: `cachedSplitDividerWidth`,
  cleared in `setConfig` and `setConfigSource`.

Body evaluations per switch (`--count-bodies`, 16 worktrees, means of 3 rounds; a range is
same repository – across repositories):

| View | Default view, before → after | Shelf, before → after |
| --- | ---: | ---: |
| `RepositorySectionView` | 20 → under 2 – 3 | 25–37 → under 2 – 2 |
| `WorktreeRow` | 16 → under 2 | 16–19 → 2 |
| `ShelfSpineView` | — | 37–76 → 11–19 |
| All Prowl `body` getters | 131–136 → 94–103 | 254–371 → 112–114 |

`_printChanges()` showed that each section evaluated about ten times per switch only
because it received `$expandedRepoIDs`; after the change the remaining evaluations report
`@self changed`.

Timing, macOS 27.0.1, Debug, 16 worktrees, two alternating blocks of six rounds per app
(medians, CPU ms / main-thread wait ms; the `idle` step is about 12 / 37):

| Interaction | Default view, before | after | Shelf, before | after |
| --- | ---: | ---: | ---: | ---: |
| Switch, same repository | 154 / 168 | 130 / 150 | 229 / 188 | 212 / 167 |
| Switch, across repositories | 146 / 166 | 131 / 151 | 233 / 190 | 214 / 168 |
| Activation | 132 / 140 | 130 / 132 | 170 / 157 | 144 / 144 |

Verification in isolated Debug instances: window screenshots of three selections in the
default view and in Shelf, and of the open command palette, differ from the base build only
in the clock and the terminal login time. With `agent-ctrl` and CoreGraphics events: row
hover actions, click selection, command-click selection within and across repositories with
the bulk menu titles, the section chevron, and spine clicks that open the expected book
behave as in the base build.

## Deviations from plan

The per-row `Equatable` step was planned as deferred; it shipped, through the generic
`EquatableContent`. The toolbar was not changed (see the plan's decisions).

## Open questions

- About 50 ms of main-thread wait per switch remains outside the views that this entry
  changed: reducers and the CLI request, the environment-driven toolbar rebuild, and the
  terminal view rebuild from `.id(worktree.id)` (about 20 ms in the default view).
- The reducer reads `repositorySettings`, `userRepositorySettings`, and `userGlobalSettings`
  from disk on each switch, because no reference keeps them loaded and the keys do not
  watch their files. Keeping them loaded needs file watching first.
