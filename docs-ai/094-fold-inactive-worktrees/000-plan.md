# 094 — Fold Inactive Worktrees: Plan

|                 |                                                                                                                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Status**      | Implemented                                                                                                                                                                                                                         |
| **Anchor date** | 2026-11-20                                                                                                                                                                                                                          |
| **Primary PRs** | #1138; discussed in #939                                                                                                                                                                                                            |
| **Related**     | [018-archived-worktrees](../018-archived-worktrees/000-plan.md), [050-sidebar-expand-active-and-worktree-tab-badges](../050-sidebar-expand-active-and-worktree-tab-badges/000-plan.md), [086-sidebar-repository-groups](../086-sidebar-repository-groups/000-plan.md), `docs/components/repositories-and-worktrees.md` |

## Background

Prowl lists every git worktree of every repository it knows. A repository that other
tools also drive accumulates worktrees nobody works on in Prowl: an orchestrator running
agents in another terminal creates a dozen `executor-NNN` worktrees, and each one gets a
sidebar row, a place in ⌘⌃↑/↓, and possibly a ⌃1–9 number. The worktrees the user works
on in Prowl end up scattered among them.

The only per-worktree hide today is archiving, which closes the worktree's terminals,
stops watching it, and makes it unselectable. That is right for finished work and wrong
for a worktree that is merely idle in Prowl.

## Goals

- A worktree with no open terminal tab in Prowl is **inactive**. Each repository folds its
  inactive worktrees into one collapsed row, "Inactive (N)", at the bottom of its section.
  One click expands it.
- Folded rows drop out of ⌘⌃↑/↓ and ⌃1–9, the same way rows of a collapsed repository do.
- Opening a folded worktree works as it does today and makes it active.

### Non-goals

- Agent detection plays no part. A worktree with an open tab stays active whether or not
  an agent runs in it, so rows do not move when an agent starts, exits, or reads `unknown`.
- No path or branch patterns, and no manual hide. Both remain possible later on top of
  the same section.
- No change to `prowl list`, notifications, the command palette, Canvas, or the Shelf.

## Design / Approach

**Active set.** `RepositoriesFeature.State.openedWorktreeIDs`, the Shelf's book set, is
the source. A tab creation adds its worktree (`tabCreatedEffect` in
`App/Sources/Features/App/Reducer/AppFeature+TerminalEvents.swift`, layout restore
included), closing the last tab removes it, and selection adds it. The sidebar and the
Shelf therefore agree on which worktrees are open.

**Always active.** The main worktree, pinned worktrees, pending (being created) worktrees,
and the selected worktree never fold.

**Folders.** Plain folders, workspaces, and remote folders have no `repository.worktrees`
to split, so they produce no sections and no rows, and they cannot fold. A remote git
repository lists its root worktree, which is its main worktree and never folds.

**Sections.** `WorktreeRowSections` in
`App/Sources/Features/Repositories/Reducer/RepositoriesFeature+StateQueries.swift` gains
`inactive: [WorktreeRowModel]`. `worktreeRowSections(in:)` splits the unpinned worktrees
into `unpinned` and `inactive`, each keeping the existing unpinned order. `allRows` keeps
returning every row, because the command palette, the Worktree menu, and CLI-facing
callers use it. A new `navigableRows` returns `allRows` minus `inactive` unless that
repository's inactive group is expanded.

**Navigation.** `worktreeID(byOffset:)` and the hotkey rows that `SidebarView` publishes as
`visibleHotkeyWorktreeRows` read `navigableRows`. `WorktreeCommands` assigns ⌃1–9 from
that list. The command palette keeps reading `orderedWorktreeRows()` over `allRows`, so
it still finds every worktree.

**Walking the group.** Selecting a worktree adds a tab to it, which would move its row
out of the group and in front of the rows after it, so a second ⌘⌃↑ from the last row
would jump past the rest of the group. A worktree selected from an expanded group is
kept in `retainedInactiveWorktreeIDs` and stays in the group, so the navigation order
holds while the group is walked. The set clears when the selection moves to a row
outside the group (the rows opened from the group then leave it) and when the group
folds. `setSingleWorktreeSelection` adds to it, which covers every path that selects
one worktree: the next/previous commands, the numbered shortcuts, history, and clicks.
A reducer that runs after every action releases the kept rows whenever the selection is
not one of them, so a selection that bypasses that helper (a plain folder, a workspace
child, Canvas, the archived list) releases them too.

**Repository groups.** The Inactive row is part of a repository's rows
(`WorktreeRowsView` inside `RepositorySectionView`), so a repository in a sidebar group
(086) shows its Inactive row inside that group, and a collapsed group hides it with the
rest. Navigation reads `navigableWorktreeRows` over the repositories that 086's
`visibleRepositoryIDs` / `visibleExpandedRepositoryIDs` leave visible, so a collapsed
group and a folded Inactive row both drop out of ⌘⌃↑/↓ and ⌃1–9.

**Fold state.** `@Shared(.appStorage("sidebarExpandedInactiveRepositoryIDs"))` holds the
repositories whose inactive group is expanded, next to `collapsedRepositoryIDs`. Default:
folded. Reload pruning drops IDs of repositories that no longer exist and keeps those of a
repository whose load failed.

**View.** `WorktreeRowsView` renders the inactive group after `unpinned` as a disclosure
row with the count, in the `.body` font of the worktree rows, then the rows when expanded.
Folded rows keep their context menus, archive and delete actions, and badges.

**Drag.** Dragging stays within a group. A move inside `unpinned` or `inactive` maps its
offsets back to positions in the repository's full unpinned order before
`unpinnedWorktreesMoved` writes `worktreeOrderByRepository`, so the stored order stays
one list.

**Docs.** `docs/components/repositories-and-worktrees.md` (the folded group) and
`docs/reference/keyboard-shortcuts.md` (folded rows are skipped).

**Tests.** Reducer and state-query tests for: the section split;
each always-active exception; folders producing no rows; a worktree moving between groups
on its first tab and its last tab closing; ⌘⌃↑/↓ and ⌃1–9 skipping folded rows and
including them when expanded; palette rows unchanged; a drag inside each group producing
the expected `worktreeOrderByRepository`; fold-state pruning.

## Alternatives & decisions

- **Hide instead of fold.** Hiding would make the palette the only way to reach an
  inactive worktree. Clicking a sidebar row is how work starts today, so folding keeps it
  one click away. Chosen: fold.
- **Agent detection as the criterion.** Detection drops an entry whenever the state reads
  `unknown` or the agent exits, so rows would jump and ⌃1–9 would renumber. Open tabs
  change only on user or CLI action. Chosen: open tabs.
- **A separate sidebar group for worktrees running an agent.** Rejected for the same
  reason; the Active Agents panel already shows which worktrees run agents.
- **Reuse archiving.** Archiving closes terminals and blocks selection. Rejected.
- **Behind a setting, default off.** A setting would leave existing sidebars unchanged.
  Rejected on #939: listing every worktree with no open tab is a shortcoming, so the
  change replaces that behavior. Chosen: always on.

## Open questions

- In a bare repository the repository root is the bare directory, and no worktree's
  working directory equals it, so no worktree counts as the main worktree and a worktree
  named `main` folds like any other without a tab. Whether a bare layout needs its own
  notion of a main worktree is a separate decision; it would also change archive, delete,
  and pin rules.

## Amendments

### 2026-11-21: minimum visible rows

A repository with few worktrees folded down to its main worktree alone after a launch
without layout restore. Each repository now shows at least three worktree rows before its
Inactive group (`minimumVisibleWorktreeRows`). Main, pinned, pending, and active rows count
first; `foldedWorktreeIDs` keeps the first inactive rows in row order until the floor is
reached and folds the rest. Row order is newest first (`GitClient` sorts by creation date,
and worktrees missing from the dragged order come first), so the newest worktrees fill the
floor. A row kept in the expanded group (`retainedInactiveWorktreeIDs`) never fills the
floor, so walking the group does not pull it out. Rejected: a lone-row rule (do not fold a
group of one); it makes the rule harder to state for one saved row.
