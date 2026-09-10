# Native Toolbar Controls Guide

This is the implementation and review reference for Prowl's macOS window toolbars. Read it
before changing a toolbar button, placement, control group, `ToolbarSpacer`,
`sharedBackgroundVisibility`, or toolbar-owned `glassEffect`.

## 1. The native model

| API | Owns | Standard use |
| --- | --- | --- |
| `ToolbarItem` | One semantic toolbar item and its placement | A single action, picker, or intentionally stable composite view. |
| `ToolbarItemGroup` | Related toolbar items | Native group surface, per-item behavior, overflow semantics, and platform spacing. This is the default for related toolbar actions. |
| `ToolbarSpacer(.fixed)` | Separation between unrelated toolbar groups | Use in placements where the toolbar honors it, especially trailing action clusters. |
| `sharedBackgroundVisibility(_:)` | Whether toolbar content participates in an adjacent shared glass surface | Use `.hidden` only when the content must not merge with its neighbors. It removes the system-provided shared background. |
| `glassEffect` | A custom view's own material | Not a replacement for `ToolbarItemGroup`. Use only when one isolated `ToolbarItem` must own a composite visual surface that native toolbar grouping cannot express. |

### Official references

- [Apple: ToolbarItemGroup](https://developer.apple.com/documentation/swiftui/toolbaritemgroup)
- [Apple: sharedBackgroundVisibility(_:)](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))
- [Apple: Refining the system-provided Liquid Glass effect in toolbars](https://developer.apple.com/documentation/swiftui/landmarks-refining-the-system-provided-glass-effect-in-toolbars)
- [WWDC25: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/) — fixed toolbar spacers and hiding shared glass background

The installed macOS 26 SwiftUI interface declares `ToolbarItemGroup` as `ToolbarContent` and
exposes `ToolbarContent.sharedBackgroundVisibility(_:)` only on macOS 26+. The app's macOS
26 deployment target satisfies that availability requirement.

## 2. Prowl toolbar audit

| Surface | Source | Current composition | Assessment |
| --- | --- | --- | --- |
| Main leading cluster (Normal, Shelf, Canvas) | `supacode/Features/Repositories/Views/WorktreeDetailView.swift` | Agents + Quick Launch use `ToolbarItemGroup(placement: .navigation)`. Bell + update use one isolated `ToolbarItem(placement: .navigation)`. | Native Agents group; verified composite exception for bell/update. |
| Main principal status | `supacode/Features/Repositories/Views/WorktreeDetailView.swift`, `ToolbarStatusView.swift` | One `.principal` status projection. | Correct: display-only content is not an action group. |
| Normal/Shelf trailing actions | `supacode/Features/Repositories/Views/WorktreeDetailView.swift`, `WorktreeDetailToolbarViews.swift` | Open action group, fixed spacers, Run item, inline custom-command group, overflow item. | Correct: semantic actions retain native toolbar ownership. |
| Canvas trailing actions | `supacode/Features/Repositories/Views/WorktreeDetailView.swift` | One `.primaryAction` item with a dynamic Run/custom-command `HStack`. | Approved stability exception: changing the number of toolbar items causes NSToolbar insert/remove animation and visible overflow. |
| Diff window | `supacode/Features/DiffView/DiffWindowContentView.swift` | Navigation sidebar toggle; principal and primary segmented pickers. | Correct native items; no custom glass. |
| Sidebar | `supacode/Features/Repositories/Views/SidebarListView.swift` | Automatic Add Repository/Workspace item. | Correct single action. |
| Archived Worktrees | `supacode/Features/Repositories/Views/ArchivedWorktreesDetailView.swift` | Automatic destructive Delete Selected item. | Correct single action. |

`HandoffHudOverlayView`, `CommandPaletteOverlayView`, and terminal tab backgrounds use
`glassEffect`, but are not window-toolbar content and are deliberately outside this guide.

## 3. The leading notification/update exception

### Required visible result

```
[ Agents | Quick Launch ]    [ Bell | Workflow History | Update ]
```

- Agents and Quick Launch remain one native shared-glass group.
- Bell and update form a second capsule immediately after it.
- The two capsules are separate.
- Bell retains its `.orange` unread state and `.secondary` idle state.
- Workflow History uses `checklist` with the same `.secondary` idle tint.
- Bell and History share a window-local `ToolbarPopoverCoordinator`. Only one owns
  presentation; late hover/dismiss callbacks from a replaced panel are ignored.
- Update retains `Color("ProwlAccent")`.

### Why it is an exception

Adjacent `.navigation` toolbar groups merge into one native shared-glass surface. A fixed
`ToolbarSpacer` does not split that leading cluster in the observed macOS 26 toolbar bridge.
Hiding the bell/update owner's shared background keeps it independent, but also removes the
system surface. Therefore `AgentNotificationsToolbarContent` uses exactly one isolated
`ToolbarItem` with all of the following:

1. `.sharedBackgroundVisibility(.hidden)` on that `ToolbarItem`;
2. an `HStack(spacing: 0)` containing `ToolbarNotificationsPopoverButton`, conditional
   `WorkflowHistoryPopoverButton`, and conditional `ToolbarUpdateButton`;
3. one outer `.glassEffect(.regular.interactive(), in: Capsule())`.

This is an ownership boundary, not a new style system. Do not add a divider, child glass,
child padding, child frame, `buttonStyle(.plain)`, or a new color while moving these controls.
The original button views own their labels, tint, tooltip, accessibility label, and popover
behavior.

### Explicitly rejected approaches

| Approach | Observed failure | Do instead |
| --- | --- | --- |
| Put Agents, Bell, and update in adjacent `.navigation` `ToolbarItemGroup`s | The toolbar merges all controls into one shared glass surface. | Keep bell/update in the isolated composite owner. |
| Use `ControlGroup` as a `ToolbarItemGroup` substitute | It changed the leading controls' surface/placement behavior and unified label rendering, losing bell and update colors. | Preserve the original button views in the approved isolated `HStack`. |
| Add glass, padding, frames, dividers, or plain button styles to bell/update children | The native proportions, accent colors, and interaction appearance drift. | Apply one glass surface only to the composite owner. |
| Move update separately to `.primaryAction` | Update appears detached from its related bell. | Keep it conditional inside the bell/update owner. |
| Duplicate this composition by mode | Normal, Shelf, and Canvas drift. | Use `AgentNotificationsToolbarContent` in every mode. |

## 4. Implementation standard

1. Start with semantic relationship, then choose the native toolbar primitive:
   - one action → `ToolbarItem`;
   - related independent actions → `ToolbarItemGroup`;
   - unrelated trailing groups → `ToolbarSpacer(.fixed)`;
   - status/display → placement-specific `ToolbarItem`.
2. Let the toolbar supply button material, hover behavior, padding, separators, and overflow
   behavior by default.
3. Treat `.sharedBackgroundVisibility(.hidden)` as an ownership boundary. Verify the resulting
   background; it may need a documented owner-drawn surface such as the leading
   notification/update exception.
4. Keep dynamic Canvas command controls in their existing single `ToolbarItem` until a live
   regression demonstrates that a multi-item structure no longer animates or overflows.
5. Centralize shared toolbar content. Do not copy it into Normal, Shelf, and Canvas paths.
6. Update this guide and the relevant `docs-ai` record when a new verified exception is added,
   removed, or its rendering changes.

## 5. Review checklist

Before committing a toolbar change:

- [ ] The chosen primitive matches the controls' semantic relationship.
- [ ] A native `ToolbarItemGroup` is used unless this guide documents the exception.
- [ ] Each `sharedBackgroundVisibility(.hidden)` has an explicit owner and visual reason.
- [ ] Existing toolbar button views have not gained incidental padding, sizing, tint, or button
      styles merely because their placement changed.
- [ ] All affected modes render the same intended order.
- [ ] The Debug build has been manually checked at normal width and a constrained width.
- [ ] For the leading cluster: generic/detected Agents, no update/update available, unread
      notification, and downloaded-update-ready states retain grouping and color.
- [ ] Tooltips, accessibility labels, menus, popovers, and shortcuts remain available.
- [ ] `make check` and `make build-app` pass.

For visual verification, use the Debug Command Palette action **[Debug] Simulate Update Found**
to expose the update control without querying Sparkle.
