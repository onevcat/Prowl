# 086.004 — Group icon

## Context

Follow-up after S2. A group header showed only its title, while a repository header can show a
user icon. onevcat asked for a folder icon on every group that changes when the group opens or
closes, and for a custom icon that is set the same way as a repository icon.

## Decisions (onevcat, 2026-10-29)

- SF Symbols has no open-folder symbol. The default icon is `folder.fill` when the group is collapsed
  and `folder` (outline) when it is open. The first version had these the other way around; onevcat
  flipped them after using it.
- A custom icon does not change with the group state. The chevron shows the state.
- Custom icons are SF Symbols and imported images. Icon suggestions are not offered: they read the
  contents of a repository, and a group has none.
- Tintable icons (symbols, SVG images) take the group color; with no group color they use the
  secondary style of the title. Other images keep their own colors. This is the repository rule.

## Change

- `App/Sources/Domain/SidebarLayout.swift`: `RepositoryGroup.icon: RepositoryIconSource?` (nil is the
  default folder), stored as `icon` in `sidebar-layout.json` with the repository icon string format.
  An icon that does not decode is dropped, not the group. `SidebarLayout.setGroupIcon(_:to:)`.
- `App/Sources/Support/ProwlPaths.swift`: `groupIconsDirectory` (`~/.prowl/group-icons/`).
  `GroupIconAssetStoreKey` reuses `RepositoryIconAssetStore` with that directory as its root.
- `RepositoriesFeature+SidebarGroups.swift`: `setGroupIcon`, the symbol picker flow
  (`chooseGroupSymbolRequested`, `symbolPickerApplied`, `symbolPickerCanceled`), and the image import
  (`importGroupImage` → `groupImageImported` or `groupImageImportFailed`, which shows an alert). Each
  import has an ID in `pendingGroupImageImports`; a later import, an explicit icon choice, or ungroup
  makes it stale, and a stale completion only deletes its own file, so the latest choice stays. A
  replaced icon, an ungrouped group, and an image that arrives after its group is gone delete the
  image file. The picker closes when its group disappears.
- `RepositoryIconImage` resolves an image from a repository or from the group icons directory
  (`init(groupIcon:tintColor:size:)`). `SidebarGroupSectionView` draws the icon before the title and
  adds the **Group Icon** menu; `ContentView` presents `TabIconPickerView` with the repository presets.

## Refs

PR: #1009
