# 061 — Native Toolbar Controls: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-08-17 | Audited every window-toolbar primitive and identified the leading notification/update and Canvas dynamic-command exceptions | Current source tree |
| 2026-08-17 | Compared the implementation with Apple toolbar guidance and the installed macOS 26 SwiftUI interface | Apple docs / Xcode 26.6 SDK |
| 2026-08-17 | Added the living native-toolbar control guide and required it from `AGENTS.md` | This record |
| 2026-08-17 | Updated the leading-cluster implementation comments and corrected stale Canvas trailing-update references | `WorktreeDetailView.swift` |
| 2026-08-17 | Amended the unified-toolbar record and user docs for the Bell + update capsule | [058.002](../058-unified-toolbar-layout/002-notification-update-group.md) |

## Outcome & current state (as of 2026-08-17)

- `docs-ai/061-native-toolbar-controls/toolbar-controls.md` is the normative implementation
  map for Prowl window toolbars. It records the official SwiftUI primitives, Prowl's source
  audit, approved exceptions, rejected approaches, and a review matrix.
- `AGENTS.md` requires the guide and a Debug visual verification before changes to a window
  toolbar control, its grouping, or Liquid Glass.
- `WorktreeDetailView.AgentNotificationsToolbarContent` remains the one shared leading
  composition for Normal, Shelf, and Canvas. Agents + Quick Launch use native
  `ToolbarItemGroup`; the isolated Bell + conditional update capsule preserves the original
  button views' color and behavior while remaining separate from Agents.
- The Canvas Run/custom-command cluster remains one dynamic `ToolbarItem`; its source comment
  now accurately describes the animation/overflow constraint without referring to a trailing
  update control.
- `docs-ai/058-unified-toolbar-layout` now records the current Bell + update behavior, and
  `docs/components/notifications.md` describes the visible grouped indicator.

## Verification

- Source audit covered every `ToolbarItem`, `ToolbarItemGroup`, `ToolbarSpacer`,
  `sharedBackgroundVisibility`, and toolbar-owned `glassEffect` under `supacode/Features/`.
- Apple documentation confirmed `ToolbarItemGroup` for logical toolbar grouping,
  `ToolbarSpacer(.fixed)` for group separation, and `sharedBackgroundVisibility(_:)` for
  shared Liquid Glass ownership. The installed Xcode 26.6 macOS 26.5 SwiftUI interface
  declares `ToolbarContent.sharedBackgroundVisibility(_:)` as available on macOS 26.
- Debug visual review confirmed the final leading arrangement: Agents stays separate; Bell and
  update share one capsule; their unread and update-accent colors remain visible.
- `make check` and `make build-app` are run for the final change set.

## Deviations from plan

The leading Bell + update capsule cannot be expressed as two adjacent native navigation groups:
the macOS 26 toolbar bridge merges those groups with Agents. The implementation therefore keeps
the original button views inside one isolated owner with one outer glass surface. This is a
narrow, documented exception rather than a replacement for `ToolbarItemGroup`.

## Open questions

- Re-verify the leading-cluster exception when upgrading the Xcode/macOS SDK: a future toolbar
  bridge may honor a fixed navigation spacer or provide a native separate-group API.
