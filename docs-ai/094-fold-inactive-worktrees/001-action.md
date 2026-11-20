# 094 — Fold Inactive Worktrees: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-20 | Fold worktrees with no open tab into a per-repository "Inactive (N)" group | #1138 |

## Outcome & current state (as of 2026-11-20)

- `worktreeRowSections(in:)` splits the unpinned worktrees into `unpinned` and
  `inactive`. A worktree is inactive when it is not in `openedWorktreeIDs`, is not the
  selected worktree, and is not in the sidebar multi-selection (`isWorktreeFolded`).
  Main, pinned, and pending worktrees are never in the unpinned list, so they never
  fold.
- `WorktreeRowsView` splits its rows with `worktreeRowSections(in:keepingUnfolded:)`,
  passing the selected worktrees its parent resolved, so its body reads no selection
  state and a worktree switch evaluates only the rows whose inputs change (093). The
  reducer-side callers use the state-derived set, `selectedWorktreeIDsKeptUnfolded`.
- Plain folders, workspaces, and remote folders have an empty `repository.worktrees`
  and produce no rows, so they cannot fold and shift no other repository's rows. A
  remote git repository lists its root worktree, which is main.
- `WorktreeRowSections.allRows` still returns every row (inactive last), so the
  command palette, the Worktree menu, and CLI-facing callers see every worktree.
  `navigableRows(isInactiveExpanded:)` and `navigableWorktreeRows(includingRepositoryIDs:)`
  drop a folded group. `worktreeID(byOffset:)`, `SidebarView`'s and
  `SidebarListView`'s hotkey rows, and `WorktreeCommands`' fallback read them, so
  ⌘⌃↑/↓ and ⌃1–9 skip folded rows.
- `retainedInactiveWorktreeIDs` keeps a worktree selected from an expanded group in
  that group, so ⌘⌃↑/↓ and ⌃1–9 walk it in row order. `setSingleWorktreeSelection`
  adds to it, and a reducer at the end of `RepositoriesFeature.body` clears it whenever the
  selection is not one of the kept rows (another worktree, a plain folder, a workspace
  child, Canvas, the archived list), and `toggleInactiveWorktreesExpanded` releases the
  repository's rows.
- `nextWorktreeID(afterRemoving:)` picks the neighbor among the navigable rows, so
  archiving or deleting the selected worktree never selects a folded row; the stored
  order decides only when the removed worktree is not among them.
- Every reducer write to `openedWorktreeIDs` goes through `addOpenedWorktreeID` and
  `removeOpenedWorktreeID`, which write only when the set changes. `@ObservableState`
  notifies on every write to a `Set`, and `WorktreeRowsView` reads the set, so a
  no-op insert on each `.selectWorktree` would re-evaluate every expanded
  repository's rows.
- `isLaunchLayoutRestorePending`, mirrored from `AppFeature.isRestoringLaunchLayout`
  at `appLaunched` and cleared in `finishLaunchLayoutRestore`, holds folding off
  while the launch layout restore re-creates tabs, so the sidebar does not show every
  row folded and then expand as `tabCreated` events arrive.
- `retainInactiveWorktree` keeps one repository's rows at a time. A `⌘`-click on a
  row of an expanded group keeps it there too, and the release reducer keeps the rows
  while the selection or a row of the multi-selection is one of them.
- With repository groups (086), the Inactive row stays per repository inside the
  group that holds it. Hotkey rows and offset navigation read `navigableWorktreeRows`
  over 086's visible repositories, so collapsed groups and folded rows both drop out.
- `sidebarExpandedInactiveRepositoryIDs` (app storage) holds the repositories whose
  group is expanded. `toggleInactiveWorktreesExpanded` flips it, and
  `repositoriesLoaded` prunes IDs of repositories that no longer exist, keeping those
  of a repository whose load failed.
- `WorktreeRowsView` renders the group after the unpinned rows as a disclosure
  button, "Inactive (N)", in `.body` like the worktree names, followed by the rows when
  expanded. A move inside either group goes through `fullUnpinnedOrderMove`, which maps
  the group offsets back to the repository's full unpinned order before
  `unpinnedWorktreesMoved` writes `worktreeOrderByRepository`. The stored order stays
  one list.
- Docs: `docs/components/repositories-and-worktrees.md` and
  `docs/reference/keyboard-shortcuts.md`.

## Verification

- `FoldInactiveWorktreesTests`: the section split, the view-side split matching the
  state-side one, the next selection after removing the selected worktree, no
  observer notification on reopening an open worktree, no folding during the launch
  restore, `⌘`-click and cross-repository kept rows, each
  always-active exception, plain and remote folders producing no rows, a worktree
  moving between groups on its first tab and its last tab closing, ⌘⌃↑/↓ and offset
  navigation skipping folded rows and including them when expanded, palette rows
  unchanged, drag mapping in each group, the fold-state toggle and its pruning
  (including a failed load), Next and Previous walking an expanded group in row
  order, the kept rows leaving when a plain folder or Canvas is selected, and
  folding inside an open and a collapsed sidebar group.
- `make check`, `make lint`, `make check-localization`, `make test-scripts`, and
  `make test` passed before the push; the PR records the counts.

## Deviations from plan

- The sidebar multi-selection also keeps rows out of the group, not only the
  selected worktree. Command-clicking a row in the expanded group would otherwise
  fold the row away under the cursor.
- The expand/fold action is a top-level `RepositoriesFeature` action next to
  `revealSelectedWorktreeInSidebar`, because it is sidebar state rather than ordering.
## Open questions

Resolved: the selected-worktree exception is needed. `ensureInitialTab` runs when
`WorktreeTerminalTabsView` appears and from a few explicit commands, and
`WorktreeTerminalState.closeTab` creates no replacement tab. Closing the last tab of
the selected worktree leaves it tabless while `tabClosedEffect` removes it from
`openedWorktreeIDs`, so without the exception the selected row would fold away.

Open: a bare repository has no main worktree by the current rule (see the plan).
