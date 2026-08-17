# 061 — Native Toolbar Controls: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-08-17 |
| **Primary PRs** | Pending |
| **Related** | [049-agents-toolbar-entry](../049-agents-toolbar-entry/000-plan.md), [058-unified-toolbar-layout](../058-unified-toolbar-layout/000-plan.md), [`AGENTS.md`](../../AGENTS.md) |

## Background

Moving the update indicator into the leading notification cluster exposed a recurring
failure mode in Prowl's macOS 26 toolbar work: visual grouping, placement, and Liquid
Glass are coupled by SwiftUI's toolbar bridge, but their interactions are not obvious from
individual view code. Iterations that substituted `ControlGroup`, restyled existing buttons,
or attached glass to the wrong owner lost placement, colors, or the native surface.

The app already contains deliberate toolbar exceptions: the shared Normal/Shelf/Canvas
leading cluster must keep Agents separate from the notification/update cluster, and Canvas
keeps its dynamic command controls inside one toolbar item to avoid NSToolbar insert/remove
animation. These decisions need one current reference rather than scattered comments and
git archaeology.

## Goals

- Audit every current window-toolbar control and record whether its grouping is native or a
  deliberate exception.
- Document the verified native SwiftUI model, including official Apple references and the
  macOS 26 SDK API boundary.
- Record the notification/update leading-cluster implementation and the failed approaches
  that must not be retried.
- Establish a short, actionable implementation and review standard for future toolbar work.
- Make the reference mandatory before changes to toolbar controls, grouping, or Liquid Glass.
- Correct stale toolbar comments discovered during the audit without changing verified UI
  behavior.

### Non-goals

- Redesigning existing toolbar controls, their actions, or their visual hierarchy.
- Replacing SwiftUI toolbar APIs with AppKit toolbar management.
- General documentation for non-toolbar `glassEffect` surfaces such as HUDs, popovers, or
  terminal tabs.

## Design / Approach

Create a living guide at
`docs-ai/061-native-toolbar-controls/toolbar-controls.md` with four durable sections:

1. **Official model** — `ToolbarItem`, `ToolbarItemGroup`, `ToolbarSpacer(.fixed)`, and
   `sharedBackgroundVisibility(_:)`, linked to Apple documentation and WWDC25 guidance.
2. **Prowl audit** — the Main, Canvas, Diff, Sidebar, and Archived Worktrees toolbars,
   including the reason for every non-default composition.
3. **Implementation standard** — native grouping by default; a narrowly scoped leading
   notification/update exception that preserves the original button views and applies one
   outer glass surface only after opting out of shared background.
4. **Review checklist** — visual state matrix, placement/grouping checks, and explicit
   prohibitions against replacing toolbar grouping with `ControlGroup`, nested glass, or
   incidental button restyling.

Add a focused `AGENTS.md` instruction that routes toolbar changes to the guide. Keep the
Normal/Shelf/Canvas composition centralized in
`WorktreeDetailView.AgentNotificationsToolbarContent`; do not create mode-specific copies.

## Alternatives & decisions

- **Rely only on comments in `WorktreeDetailView.swift`:** rejected. They cannot capture the
  full audit, official API boundary, historical failure modes, and review matrix.
- **Use `ControlGroup` as a universal replacement for `ToolbarItemGroup`:** rejected. It is a
  view container, not toolbar content; in the observed leading-cluster case it altered
  placement, shared surface, and label-color behavior.
- **Use `glassEffect` for every related toolbar button:** rejected. Native toolbar grouping is
  the default; manually layered glass is reserved for the verified isolated composite where
  a shared toolbar group cannot remain separate from Agents.
- **Move all toolbar composition into AppKit:** rejected. SwiftUI's native toolbar APIs cover
  the app's current needs, and the documented exceptions are smaller and safer.

## Verification

- Confirm the audit covers every `ToolbarItem`, `ToolbarItemGroup`, `ToolbarSpacer`, and
  toolbar-owned `glassEffect` in the app source.
- Confirm the guide's Apple API claims against both official Apple documentation and the
  installed macOS 26 SwiftUI interface.
- Run `make check` and `make build-app`.
- Live-inspect the Debug app's leading cluster with update simulated: Agents is separate;
  bell and update share one capsule; unread and update accent colors remain visible.

## Amendments
