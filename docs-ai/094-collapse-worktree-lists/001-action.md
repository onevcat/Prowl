# 094 — Collapse Long Worktree Lists: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-20 | Fold worktrees with no open tab into a per-repository "Inactive (N)" group | #1138 |
| 2026-11-21 | Replace the Inactive group with in-place hiding behind Show N More / Show Less | takeover of #1138 |

## Outcome & current state (as of 2026-11-21)

- `WorktreeRowSections` keeps `main`, `pinned`, `pending`, and `unpinned` in row order and
  adds `hideableIDs`: unpinned rows past the first `collapsedRowCount` (3) rows with no
  open tab and not selected (`isWorktreeHideable`). `visibleRows(isShowingAll:)` drops
  them unless the repository shows all; `allRows` lists everything for the palette and the
  Worktree menu.
- `footer(isShowingAll:)` decides the control: **Show N More** when rows are hidden,
  **Show Less** (disabled when nothing could be hidden) when showing all with more than
  three rows, else none. `WorktreeRowsView.worktreeListFooter` draws it.
- `showAllWorktreesRepositoryIDs` (app storage `sidebarShowAllWorktreesRepositoryIDs`)
  and `toggleShowAllWorktrees` hold the per-repository state; `repositoriesLoaded` prunes
  removed repositories and keeps one whose load failed.
- `navigableWorktreeRows`, `worktreeID(byOffset:)`, the sidebar hotkey rows,
  `WorktreeCommands`, and `nextWorktreeID(afterRemoving:)` read the visible rows.
- `fullUnpinnedOrderMove` maps a drag among the visible unpinned rows to the stored order.
- `isLaunchLayoutRestorePending` hides nothing during the launch layout restore.
- `addOpenedWorktreeID` / `removeOpenedWorktreeID` write only on change (093).
- Removed with the Inactive group: `SidebarWorktreeSection.inactive`,
  `retainedInactiveWorktreeIDs` and the reducer that cleared it, the ⌘-click retention in
  `setSidebarSelectedWorktreeIDs`, and `sidebarExpandedInactiveRepositoryIDs`.
- Docs: `docs/components/repositories-and-worktrees.md` and
  `docs/reference/keyboard-shortcuts.md`.

## Verification

- `WorktreeListCollapseTests`: the first three rows, rows with tabs staying in place, a tab
  in the first rows showing no extra row, pinned rows taking the first places and all
  showing past three, selected, multi-selected, and pending rows, a repository without a
  main worktree, the view split matching the state split, the launch restore, folders,
  palette rows, show all keeping stored order, Show Less disabled, the toggle and its
  pruning, a hidden row showing on its first tab and hiding on its last tab close, no
  observer notification on reopening, navigation and walking, a collapsed sidebar group,
  the next selection after removing the selected worktree, and drag mapping.
- A Debug instance on sample repositories (8, 4, and 2 worktrees besides main) for the
  visual check.

## Deviations from plan

- None beyond the redesign recorded in the plan's Alternatives.
