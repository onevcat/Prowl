# 086 — Sidebar Repository Groups: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-10-29 |
| **Primary PRs** | (fill in as they merge) |
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
  the IDs of hidden remote folders in place (`keepsHiddenRemoteID`, `mergingHiddenRepositoryIDs`, docs-ai 084).

### Order consumers

`RepositoriesFeature.State.orderedRepositoryRoots()` flattens the layout. All current consumers go through
`orderedRepositoryIDs()`: `orderedWorktreeRows` (hotkeys and Cmd+Ctrl+Up/Down), `ListRuntimeSnapshotBuilder`,
`ShelfBook`, `ToolbarNotificationGroup`, and `WorktreeCommands`. They follow the sidebar with no other change.

### Collapse semantics

- A worktree row is visible when its group (if any) is expanded and its repository is expanded. The worktrees
  of a collapsed group are not in the hotkey rows or the keyboard navigation, the same as a collapsed repository.
- A sidebar reveal (`pendingSidebarReveal`) of a worktree in a collapsed group expands the group and the repository.
- The header toggle treats groups and repositories as one set of expandable nodes, so
  `SidebarListView.repositoryListHeaderAction` keeps its pure derivation. Collapse All leaves only group headers
  and ungrouped repository headers. Expand Active expands the groups that contain an active repository, and those
  repositories.

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

### Drag and drop

- One pure function computes the layout change from the dragged item (repository or group) and the drop target
  (row, top or bottom half, top level or in a group). Unit tests cover the edge cases before the
  `DropDelegate` uses it. The current code is in `App/Sources/Features/Repositories/Views/SidebarDragSupport.swift`.
- A group drops only at a top-level position. A drop on a group header puts a repository at the end of that group.

### Slices

| Slice | Content |
| --- | --- |
| S1 | Layout model, persistence, migration, flattened order, group container rendering, collapse, header toggle, context menus, docs |
| S2 | Drag and drop: repositories in and between groups and the top level, whole-group drag |
| S3 | Group color background (can move into S1 after the visual check) |

Each slice updates `docs/components/repositories-and-worktrees.md` and gets a Debug visual check.

## Alternatives & decisions

- **Layout tree instead of a flat order plus group membership.** A flat order with groups as contiguous runs
  keeps `repositoryOrderIDs`, but an empty group then has no position, and every edit must keep the runs
  contiguous. The tree has no such invariant.
- **Groups mix with ungrouped repositories** (onevcat, 2026-10-29). #996 suggests groups first and ungrouped
  repositories after them. Mixed order is more general, and a user who wants groups first can drag them there.
- **A collapsed group does not contribute hotkey rows** (onevcat, 2026-10-29). Same rule as a collapsed repository.
- **Context menus first, drag in a separate slice** (onevcat, 2026-10-29). Drag is the highest risk. The menus
  give a reliable and accessible path for every operation, and S1 can ship without drag.
- **Group color is a background only, not inherited** (onevcat, 2026-10-29). Inheritance changes what a repository color means in
  Active Agents, Shelf, and Canvas. A quiet background separates the group and keeps the sidebar calm.
- **Not in `settings.json`.** #996 suggests `settings.json`, but repository order is not stored there today.
  A separate file follows the repository appearances file.

## Amendments
