# 086 — Sidebar Repository Groups: Plan

| | |
| --- | --- |
| **Status** | In progress |
| **Anchor date** | 2026-10-29 |
| **Primary PRs** | #1006 (plan) |
| **Related** | Issue #996, #413 (Canvas groups), #601 (cross-repository pins), `docs/components/repositories-and-worktrees.md` |

## Background

The sidebar shows one flat list of repositories. The only ways to organize it are drag to reorder and
repository colors. A user with many repositories (#996: 14 repositories in a few product lines) finds a
repository by its position, and the list shows no boundary between related repositories. A `customTitle`
prefix and a shared color mark a group, but there is no group header and a group cannot collapse.
Workspaces are not a replacement: a workspace adds an entry next to the original repositories, and its
child rows do not offer repository actions such as creating or archiving a worktree.

## Goals

- Create, rename, and ungroup named groups of repositories in the sidebar.
- Groups and ungrouped repositories mix at the top level, in an order that the user sets.
- A group collapses and expands. The state persists.
- The Expand Active / Expand All / Collapse All control also applies to groups.
- A group can have a color. The group shows it as a quiet translucent background behind its header and members.
- Drag to reorder: repositories in a group, repositories into and out of a group, and a whole group.
- The sidebar order is the single order that worktree hotkeys, keyboard navigation, `prowl list`, Shelf, and
  toolbar notifications follow.

### Non-goals

- Nested groups. A group holds repositories only.
- Group colors that repositories inherit (Active Agents, Shelf, and Canvas keep the repository's own color).
- Groups in Canvas and Shelf (#413), and a group field in `prowl list`. These can come later.
- Automatic group suggestions from parent directories.
- Compatibility with an older app version after a downgrade.

## Design / Approach

### Model and persistence

```swift
struct RepositoryGroup: Codable, Equatable, Identifiable {
  let id: UUID
  var title: String
  var color: RepositoryColorChoice?
  var repositoryIDs: [Repository.ID]
}

enum SidebarLayoutItem: Codable, Equatable {
  case repository(Repository.ID)
  case group(RepositoryGroup)
}
```

- `[SidebarLayoutItem]` is the sidebar layout and the only source of repository order. It replaces the
  `repositoryOrderIDs` app storage value that `RepositoryPersistenceClient` reads and writes today.
- The layout persists in `~/.prowl/sidebar-layout.json` through a `SharedKey`, the same pattern as
  `RepositoryAppearancesKey` (`repository-appearances.json`). The file is readable and a user can edit it.
- Migration: when the file does not exist, the layout is `repositoryOrderIDs` as `.repository` items.
- Collapsed groups persist in app storage as `sidebarCollapsedGroupIDs`, next to
  `sidebarCollapsedRepositoryIDs`. Collapse is view state, so it does not go into the layout file.
- Invariants: a repository occurs one time in the layout. A new repository goes to the end of the top level. A
  removed repository leaves its group. An empty group stays and shows a drop placeholder. Normalization keeps
  the IDs of hidden remote folders in place, inside their groups too (`keepsHiddenRemoteID`, docs-ai 084). The
  flat `mergingHiddenRepositoryIDs` helper does not fit a tree, so the layout gets its own merge with the same
  rules: prune against roots and loaded repositories, skip pruning for a snapshot, keep hidden remote-form IDs.

### Order consumers

`RepositoriesFeature.State.orderedRepositoryRoots()` flattens the layout. These consumers go through
`orderedRepositoryIDs()` and follow the sidebar with no other change: `orderedWorktreeRows` (hotkeys,
Cmd+Ctrl+Up/Down, command palette worktrees), `ListRuntimeSnapshotBuilder` (`prowl list`, and through the CLI
router the Remote Mirror list and new-pane catalog), `ShelfBook`, `ToolbarNotificationGroup`, and
`WorktreeCommands`. Orders that do not use the sidebar order today stay as they are: Canvas card layout, Agent
Island navigation, and the initial fallback selection in `RepositoriesFeature+Selection.swift`.

### Collapse semantics

Two things are separate: the **own expansion** of a group or a repository (what the user set), and the
**effective visibility** of a repository's rows (its own expansion and its group's expansion).

- Own expansion persists as now: `sidebarCollapsedRepositoryIDs` for repositories, `sidebarCollapsedGroupIDs` for
  groups. Collapsing a group does not change the own expansion of its members, so reopening the group restores them.
  The `SidebarView` binding writes own expansion only; it must not write the effective projection back.
- A new effective projection feeds hotkey rows and keyboard navigation (`orderedWorktreeRows`, the
  `worktreeID(byOffset:)` path). The worktrees of a collapsed group are not in it, the same as a collapsed repository.
- Only an explicit reveal expands a collapsed group, the same rule as a collapsed repository today:
  `revealSelectedWorktreeInSidebar` removes the group from `sidebarCollapsedGroupIDs` as well as the repository
  from `sidebarCollapsedRepositoryIDs`. The reveal also covers a selected plain folder or workspace header in a
  collapsed group. Selection by itself does not change collapse state. The command palette toggle and terminal
  layout restore send `selectWorktree` / `selectRepository` for the current target
  (`AppFeature+TerminalEvents.swift`), and these must leave a collapsed group shut.
- The header toggle derives its action from effective state: a node is expanded when it is a group that is open,
  or a repository that is visible and open. With every group shut, nothing is effectively expanded, so the toggle
  offers Expand Active or Expand All. `SidebarListView.repositoryListHeaderAction` stays pure but gets
  group-aware inputs.
- Header actions write own expansion for both kinds: Expand All opens all groups and expandable repositories.
  Collapse All shuts all of them. Expand Active opens the groups that contain an active member and the active
  expandable repositories, and shuts the rest.
- Group activity counts open tabs of **all** member kinds, including plain folders (the tab count in
  `RepositorySectionView` already supports them). Today `SidebarListView.activeRepositoryIDs` excludes plain
  folders, which was harmless while their headers could not collapse. Repository expansion still applies only to
  expandable members.

### Sidebar rendering

- `SidebarPresentation` gets a group item that contains its member repository items. A group renders as one
  container (header plus members), not as a header row followed by flat rows. The color background and the
  whole-group drag need the container.
- The group header is light: chevron, title, member count. Members have no extra indent. A colored group draws a
  low-opacity fill of its system color with a small corner radius. The final opacity and spacing are set during
  a Debug visual check.

### Actions

- Repository context menu: New Group…, Move to Group (submenu), Remove from Group.
- Group header context menu: Rename…, Color, Ungroup. Ungroup puts the members at the group's position and
  removes no repository.
- All layout changes are reducer actions with tests (`RepositoriesFeature`).
- The menus give a path for membership and group edits, not for arbitrary order. In S1, members keep the order
  in which they joined the group, and groups keep their creation position.

### Edge cases

- A repository that fails to load stays in its group and shows its failure row inside the group container.
- A group title is trimmed and must not be empty. Duplicate titles are allowed; the group ID is a UUID.
- A new repository goes to the end of the top level, also when a group is selected.

### Drag and drop

- One pure function computes the layout change from the dragged item (repository or group) and the drop target
  (row, top or bottom half, top level or in a group). Unit tests cover the edge cases before the
  `DropDelegate` uses it. The current code is in `App/Sources/Features/Repositories/Views/SidebarDragSupport.swift`.
- A group drops only at a top-level position. A drop on a group header puts a repository at the end of that group.
- S1 changes the list from flat rows to a tree, so the current flat-index repository drag cannot stay as is. In
  S1, only ungrouped top-level repositories are drag sources, and their drop positions are top-level layout
  positions (groups count as one position). Group headers and group members are not drag sources until S2.

### Slices

| Slice | Content |
| --- | --- |
| S1 | Layout model, persistence, migration, flattened order, group container rendering, collapse, header toggle, context menus, docs |
| S2 | Drag and drop: repositories in and between groups and the top level, whole-group drag |
| S3 | Group color background (moved into S1, see [002-s1.md](002-s1.md)) |

Each slice updates `docs/components/repositories-and-worktrees.md` and gets a Debug visual check.

## Alternatives & decisions

- **Layout tree instead of a flat order plus group membership.** A flat order with groups as contiguous runs
  keeps `repositoryOrderIDs`, but an empty group then has no position, and every edit must keep the runs
  contiguous. The tree has no such invariant.
- **Groups mix with ungrouped repositories** (onevcat, 2026-10-29). #996 suggests groups first and ungrouped
  repositories after them. Mixed order is more general, and a user who wants groups first can drag them there.
- **A collapsed group does not contribute hotkey rows** (onevcat, 2026-10-29). Same rule as a collapsed repository.
- **Context menus first, drag in a separate slice** (onevcat, 2026-10-29). Drag is the highest risk. The menus
  give a reliable and accessible path for group membership and group edits, and S1 can ship without drag.
  Arbitrary order inside a group and group moves wait for S2.
- **Own expansion separate from effective visibility.** Filtering the stored expansion by group state would let
  the existing binding record hidden members as collapsed, and a reopened group would lose their state.
- **Group color is a background only, not inherited** (onevcat, 2026-10-29). Inheritance changes what a repository color means in
  Active Agents, Shelf, and Canvas. A quiet background separates the group and keeps the sidebar calm.
- **Not in `settings.json`.** #996 suggests `settings.json`, but repository order is not stored there today.
  A separate file follows the repository appearances file.

## Amendments

- Updated 2026-10-29: S1 shipped the layout, groups, collapse, menus, and the color background (S3 folded into S1) — see [002-s1.md](002-s1.md)
