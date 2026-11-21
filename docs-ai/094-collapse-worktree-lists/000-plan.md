# 094 — Collapse Long Worktree Lists: Plan

|                 |                                                                                                                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Status**      | Implemented                                                                                                                                                                                                                         |
| **Anchor date** | 2026-11-20                                                                                                                                                                                                                          |
| **Primary PRs** | #1138 (opened by a contributor) and its takeover; discussed in #939                                                                                                                                                                 |
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

- A long worktree list collapses by default: it shows its first four rows, every pinned
  worktree, and every worktree with an open tab, and hides the rest behind
  **Show N More**. **Show Less** collapses it again.
- The list keeps one order. Collapsing hides rows in place; it never moves a row, so a
  worktree that gets or loses a tab does not jump.
- Hidden rows drop out of ⌘⌃↑/↓ and ⌃1–9, the same way rows of a collapsed repository do.
- No setting (#939: listing every worktree is a shortcoming, so the change replaces that
  behavior).

### Non-goals

- Agent detection plays no part. A worktree with an open tab stays visible whether or not
  an agent runs in it, so rows do not change when an agent starts, exits, or reads
  `unknown`.
- No path or branch patterns, and no manual hide.
- No change to `prowl list`, notifications, the command palette, Canvas, or the Shelf.

## Design / Approach

**Row order.** Unchanged: main, pinned, pending, then the unpinned worktrees in their
stored order. `GitClient` sorts worktrees newest first, and worktrees missing from a
dragged order come first, so without a drag the newest worktrees lead.

**What a collapsed list hides.** `worktreeRowSections(in:)` in
`App/Sources/Features/Repositories/Reducer/RepositoriesFeature+StateQueries.swift` marks
an unpinned row as hideable (`WorktreeRowSections.hideableIDs`) when it is past the first
`WorktreeRowSections.collapsedRowCount` (4) rows of the repository and
`isWorktreeHideable` holds: it is not in `openedWorktreeIDs` and not selected. Main,
pinned, and pending rows are never hideable, and they count toward the first four. The
first four are a position, not a tab count, so opening a tab never changes which other
rows show. A repository without a main worktree (a bare layout) shows its first four rows.

**Open tabs.** `RepositoriesFeature.State.openedWorktreeIDs`, the Shelf's book set, is the
source. A tab creation adds its worktree (`tabCreatedEffect`, layout restore included),
closing the last tab removes it, and selection adds it. `addOpenedWorktreeID` and
`removeOpenedWorktreeID` write only when the set changes, because `@ObservableState`
notifies on every `Set` write and `WorktreeRowsView` reads the set (093).

**Selected rows stay.** Closing the last tab of the selected worktree leaves it tabless
(`ensureInitialTab` runs only when the tabs view mounts), so the selected worktree and the
sidebar multi-selection are never hidden. `WorktreeRowsView` passes the selection its
parent resolved (`keepingVisible:`), so its body reads no selection state (093).

**Launch.** `isLaunchLayoutRestorePending`, set at `appLaunched` while the layout restore
runs and cleared in `finishLaunchLayoutRestore`, hides nothing until the restored tabs are
back in `openedWorktreeIDs`.

**Show all.** `@Shared(.appStorage("sidebarShowAllWorktreesRepositoryIDs"))` holds the
repositories whose list shows every row; `toggleShowAllWorktrees` flips it. Reload pruning
drops IDs of repositories that no longer exist and keeps those of a repository whose load
failed.

**Footer.** `WorktreeRowSections.footer(isShowingAll:)`: a collapsed list with hidden rows
shows **Show N More**; a list that shows all and has more than four rows shows
**Show Less**, disabled while no row could be hidden; otherwise nothing. `WorktreeRowsView`
draws it below the rows in `.subheadline`, secondary, inset to the worktree names, so it
does not read as another worktree.

**Navigation.** `visibleRows(isShowingAll:)` is every row minus the hidden ones.
`navigableWorktreeRows` reads it for `worktreeID(byOffset:)`, the hotkey rows that
`SidebarView` and `SidebarListView` publish, and `WorktreeCommands`. The command palette
and the Worktree menu read `orderedWorktreeRows()` / `allRows`, so they still list every
worktree. `nextWorktreeID(afterRemoving:)` picks among the visible rows.

**Drag.** A collapsed list shows a subset of the unpinned rows. `fullUnpinnedOrderMove`
maps a move among the visible unpinned rows to the full stored order, so hidden rows keep
their place between the visible ones.

**Folders and groups.** Plain folders, workspaces, and remote folders have no worktree
list to collapse; a remote git repository lists only its main worktree. The footer is part
of a repository's rows, so a collapsed sidebar group (086) hides it with them.

## Alternatives & decisions

- **A separate "Inactive (N)" group at the bottom of each repository.** Implemented first
  (#1138 as opened). Rows moved between the group and the list whenever a tab opened or
  closed, so walking the expanded group with ⌘⌃↓ needed extra state to keep rows in place
  (`retainedInactiveWorktreeIDs` and a reducer clearing it after every action), drag had
  to stay within a group, and the disclosure row read as one more worktree, which left
  users asking where their worktrees went. Replaced by hiding rows in place.
- **A visible-row floor that counts open tabs.** Tried with a floor of three: opening a
  tab in a hidden worktree pushed another row out of view. A positional floor does not.
- **Hide entirely.** The palette would be the only way to reach a hidden worktree.
  Rejected: **Show N More** keeps it one click away.
- **Agent detection as the criterion.** Detection drops an entry whenever the state reads
  `unknown` or the agent exits, so rows would come and go. Open tabs change only on user
  or CLI action. Chosen: open tabs.
- **Behind a setting.** Rejected on #939. Chosen: always on.

## Open questions

- A bare layout has no main worktree, so its default-branch worktree counts as an ordinary
  row and can be hidden. Whether a bare layout needs its own notion of a main worktree is
  a separate decision; it would also change archive, delete, and pin rules.
