# 086 — Sidebar Repository Groups: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-29 | Plan merged | #1006 |
| 2026-10-29 | S1: layout tree in `sidebar-layout.json` with migration from `repositoryOrderIDs`, flattened order for every order consumer, group containers, own versus effective collapse, header toggle over groups, context menus, and the color background (S3 folded in) | #1007, [002-s1.md](002-s1.md) |
| 2026-10-29 | S2: drag and drop for repositories in, into, and out of groups, and for whole groups, through one pure `SidebarLayout.move(_:to:)` | #1008, [003-s2.md](003-s2.md) |
| 2026-10-29 | Group icon: default folder (`folder` collapsed, `folder.fill` open), user SF Symbol or imported image in `~/.prowl/group-icons/` | [004-group-icon.md](004-group-icon.md) |

## Outcome & current state (as of 2026-10-29)

- **Model.** `App/Sources/Domain/SidebarLayout.swift`: `[SidebarLayoutItem]` (ungrouped repository or
  `RepositoryGroup`) is the only repository order. Every edit, menu or drag, is a pure function on
  `SidebarLayout` and goes through `editSidebarLayout` in
  `App/Sources/Features/Repositories/Reducer/RepositoriesFeature+SidebarGroups.swift`, which starts from
  the materialized layout and saves only on a change.
- **Storage.** `App/Sources/Clients/Repositories/SidebarLayoutKey.swift` keeps `~/.prowl/sidebar-layout.json`;
  group collapse is app storage (`sidebarCollapsedGroupIDs`); imported group icon images are in
  `~/.prowl/group-icons/`.
- **Sidebar.** `SidebarGroupSectionView` renders a group container; `SidebarListView` wires the
  collapse toggle, the menus, and the drag context. `SidebarDropRow` in
  `App/Sources/Features/Repositories/Views/SidebarDragSupport.swift` maps a drop location to a
  `SidebarDropDestination`.
- **Order consumers.** Worktree hotkeys, keyboard navigation, `prowl list`, Shelf, and toolbar
  notifications follow `orderedRepositoryIDs()`; a collapsed group contributes no hotkey rows.

## Deviations from plan

- S3 (group color) shipped in S1; see [002-s1.md](002-s1.md).
- Drop destinations are anchors instead of offsets, which changes how hidden entries keep their place;
  see [003-s2.md](003-s2.md).

## Open questions

- No spring-loaded opening: a drag that hovers a collapsed group does not open it.
