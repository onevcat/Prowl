# 058 — Unified Toolbar Layout: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-08-07 | Removed the persistent branch/folder/workspace toolbar title and hid the visible Canvas title | #689 |
| 2026-08-07 | Unified Normal, Shelf, and Canvas around one leading Agents + Quick Launch cluster followed by a separately surfaced notifications capsule | #689 |
| 2026-08-07 | Moved Rename Branch to the worktree row context menu and app-level sheet while retaining the command/shortcut path | #689 |
| 2026-08-07 | Made Hand Off resolve the focused Canvas card through the shared action-target resolver; added a reducer regression test | #689 |
| 2026-08-07 | Updated user documentation and corrected superseded toolbar references in earlier `docs-ai` entries | #689 |
| 2026-08-07 | Hardened rename presentation/command targeting and removed review-identified toolbar state/style drift | #689 |

## Outcome & current state (as of 2026-08-07)

- `supacode/Features/Repositories/Views/WorktreeDetailView.swift` always applies
  `.toolbar(removing: .title)`, preserving `WindowTitle.compute(...)` for window identity
  without rendering a toolbar title. `AgentNotificationsToolbarContent` is the shared
  leading composition for all three view modes.
- Agents and Quick Launch remain a native shared-glass group. Bell and the conditional update
  indicator follow in a separate leading capsule, preserving the visual gap that previously
  separated Agents from the branch title. The implementation is centralized in
  `AgentNotificationsToolbarContent`; see [002-notification-update-group.md](002-notification-update-group.md).
- `supacode/Features/Repositories/Views/ToolbarNotificationsPopoverButton.swift` and
  `ToolbarUpdateButton.swift` retain their original button-owned tint, tooltip, accessibility,
  and interaction behavior. The isolated owner supplies the shared capsule; see
  [061 Native Toolbar Controls](../061-native-toolbar-controls/toolbar-controls.md) for the
  documented macOS 26 exception and review standard.
- Normal, Shelf, and Canvas receive one assembled `ToolbarSharedState`; only their documented
  `ToolbarContent` structure differs. Canvas resolves the Agents capsule and profile launcher
  from the focused card. With no focused card, Quick Launch/profile rows are omitted instead
  of presenting actions with no destination; profile management remains available.
- The former title-only implementation and tests were removed. Branch names continue to
  appear in the sidebar and terminal/agent-owned context, where they remain useful without
  consuming permanent toolbar width.
- `supacode/Features/Repositories/Views/RenameBranchPromptView.swift` retains the rename
  form. `supacode/App/ContentView.swift` presents it with `sheet(item:)` from an identifiable,
  self-contained `PendingRenameBranchRequest`, keyed by request ID. A final repositories
  reducer enforces that pending prompts only target existing, non-archived worktrees.
- `supacode/Features/Repositories/Views/WorktreeRowsView.swift` adds **Rename Branch…** to
  single-worktree context menus and advertises the configured shortcut. The Worktrees menu
  uses a focused action backed by one Canvas-aware target query; bulk selection, unresolved
  worktrees, and competing modal presentations disable it. Unchanged Return dismisses the
  sheet without invoking Git.
- `supacode/Features/App/Reducer/AppFeature+Handoff.swift` now uses the existing
  Canvas-aware `actionTargetWorktree` resolver. The Canvas Agents button therefore opens
  Hand Off for the focused card rather than silently no-oping when sidebar selection is
  `.canvas`.
- Current user behavior is documented in `docs/components/notifications.md`,
  `docs/components/handoff.md`, and `docs/components/repositories-and-worktrees.md`.

## Verification

- TDD regression: `openHandoffHudUsesCanvasFocusedWorktree()` failed before the resolver
  change and passed afterward.
- Targeted `xcodebuild test`: the original Hand Off / Rename coverage passed, plus eight
  review-hardening regressions for Canvas targeting, bulk/modal/pending gates, and request
  invalidation after reload/archive.
- `make check`: changed-file formatting, strict `swift-format` lint, and SwiftLint passed.
- `make build-app`: Debug build passed with zero errors and zero warnings.
- Live Debug app inspection:
  - Normal: no branch item; Agents + Quick Launch render separately from the Bell + update capsule.
  - Canvas: no visible `Canvas` title; the same leading controls render against the
    focused-card toolbar.
  - Shelf: the same leading order and separation are retained.
  - The tested window width kept editor, run, custom-command, and update controls visible
    without branch-name pressure.
  - Rename opened with its text field as the AX first responder and the current branch
    prefilled; the reported FocusState timing risk (#9) was not reproducible, so no speculative
    focus workaround was added.
  - Return with an unchanged name dismissed the sheet; Rename was disabled while that sheet
    was open, and enabled in Canvas against the focused card with the correct branch name.

## Deviations from plan

- The initial shared-layout implementation placed Bell inside the Agents shared-glass
  group. During live review, the desired separation was clarified: Bell and the conditional
  update indicator now share a standalone capsule with the same gap as the removed branch item.
- Removing the toolbar anchor required the rename form to move from a popover to an
  app-level sheet. The form and reducer request model remain intact.
- Adding Agents to Canvas exposed that Hand Off still resolved only
  `selectedTerminalWorktree`; the implementation expanded to align that reducer path with
  the existing Canvas-aware action resolver and added regression coverage.

## Open questions

- None.
