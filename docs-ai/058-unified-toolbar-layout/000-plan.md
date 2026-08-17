# 058 — Unified Toolbar Layout: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-08-07 |
| **Primary PRs** | #689 |
| **Related** | [049-agents-toolbar-entry](../049-agents-toolbar-entry/000-plan.md), [052-sidebar-context-menus](../052-sidebar-context-menus/000-plan.md), [`docs/components/notifications.md`](../../docs/components/notifications.md), [`docs/components/repositories-and-worktrees.md`](../../docs/components/repositories-and-worktrees.md) |

## Background

The Normal and Shelf toolbars dedicate a persistent navigation item to the current branch. The item also acts as an entry point for renaming the branch. Canvas instead exposes a persistent `Canvas` title, has no Agents control, and keeps notifications in the trailing action area.

The branch item has low actionable value:

- The selected branch is already visible in the sidebar.
- Agent terminal status bars commonly expose the branch as part of their own context.
- Branch renaming is a low-frequency management action and does not justify permanent toolbar width.
- Long branch names create an oversized capsule and poor visual balance.
- On narrow windows, that unbounded item competes with agent, notification, editor, run, custom-command, and update controls, causing toolbar items to collapse into overflow.

The persistent title therefore duplicates information while making the highest-frequency toolbar controls less reliable. Canvas compounds the problem by using a different leading layout even though users move between all three modes during the same orchestration workflow.

### Before / after

| Mode | Before | Planned after |
| --- | --- | --- |
| Normal | `Agents → Quick Launch → Branch`; bell in trailing actions | `Agents → Quick Launch → Bell`; no branch item |
| Shelf | Same worktree toolbar as Normal, including branch | Same leading cluster as Normal; no branch item |
| Canvas | Visible `Canvas` title; no Agents control; bell in trailing actions | No visible title; focused card's `Agents → Quick Launch → Bell` cluster |

## Goals

- Remove the branch/title item from the top toolbar in every mode.
- Remove the visible `Canvas` toolbar title while retaining the computed title for window identity.
- Give Normal, Shelf, and Canvas the same leading control order and native grouping.
- Resolve the Canvas Agents control from the currently focused Canvas worktree and pane.
- Move branch rename to the worktree row context menu while preserving the existing rename prompt and command path.
- Reduce overflow pressure and eliminate layout distortion from long branch names.
- Keep notification behavior, update behavior, and command execution semantics unchanged.

### Non-goals

- Removing branch rename as a capability.
- Removing branch names from the sidebar, terminal content, window identity, or agent-owned status bars.
- Redesigning the Agents popover, notification popover, update button, or command clusters.
- Changing Canvas focus semantics or notification read state.
- Introducing custom truncation or a bespoke responsive toolbar system.

## Design / Approach

### Shared leading cluster

Introduce one `ToolbarContent` composition in `supacode/Features/Repositories/Views/WorktreeDetailView.swift` for:

1. `AgentsToolbarButton`
2. `AgentsQuickLaunchButton` when a recommended profile exists
3. `ToolbarNotificationsPopoverButton`

Normal, Shelf, and Canvas will all use this composition with `.navigation` placement. Agents and Quick Launch remain one native shared-glass group. The bell is a separate navigation item that opts out of that shared background and draws its own glass capsule, preserving the same visual gap that previously separated Agents from the branch item. One shared implementation prevents mode-specific ordering and spacing from drifting again.

### Canvas target resolution

Refactor the Agents state assemblers to accept an explicit target worktree. Normal and Shelf pass the selected terminal worktree; Canvas passes the focused Canvas worktree. The capsule identity, hand-off source, profile recommendation, and launch destination must all refer to the same target.

### Title removal

Apply `.toolbar(removing: .title)` in every mode. Keep `WindowTitle.compute(...)` as the `navigationTitle` so AppKit window identity and the Window menu continue to report `Canvas` or the active repository/tab even though the title is not rendered in the toolbar.

Delete the branch-specific toolbar title model and view after their presentation responsibility is removed.

### Rename relocation

Keep `PendingRenameBranchRequest` and the rename form, but present the form from the app's sheet layer rather than anchoring it to a toolbar item. Add **Rename Branch…** to each single-worktree sidebar context menu, targeting the row that opened the menu even when it is not selected. Preserve the existing command/shortcut entry for keyboard users.

### Documentation

Update current behavior under `docs/` and cross-link this decision from the earlier Agents toolbar record so historical rationale does not imply the removed branch item remains current.

## Alternatives & decisions

- **Truncate the branch capsule:** rejected because it still spends persistent width on duplicate, low-frequency information and leaves rename over-promoted.
- **Replace the branch name with an icon-only rename button:** rejected because rename frequency does not justify any permanent toolbar entry.
- **Keep notifications trailing:** rejected because the bell is a high-frequency attention surface and aligning it after Agents creates one stable leading orchestration cluster in every mode.
- **Hide Agents in Canvas:** rejected because Canvas is the primary multi-agent monitoring mode; omitting the agent-scoped entry there is inconsistent with its purpose.
- **Merge Bell into the Agents shared-glass group:** rejected because the controls need the same visual separation that previously existed between Agents and the branch item.
- **Implement mode-specific copies:** rejected because the desired layout is intentionally identical and shared composition prevents future drift.

## Verification

- Build the macOS app and run the relevant unit suite.
- Verify Normal, Shelf, and Canvas show the same leading control order.
- Verify Canvas has no visible `Canvas` title and follows the focused card's agent/profile state.
- Verify long branch names no longer affect toolbar width.
- Verify the worktree context menu opens a prefilled rename prompt for the clicked row.
- Verify notification, update, editor, run, and custom-command controls still behave as before.

## Amendments

### 2026-08-07 — Review hardening

A deep review of #689 identified lifecycle and command-target drift introduced when Rename Branch moved from a
window-scoped toolbar popover to an app-level sheet and menu command. The follow-up keeps the original product
direction while hardening its implementation:

- Present rename from an identifiable, self-contained request and invalidate the request whenever its worktree
  disappears.
- Resolve the keyboard command through one Canvas-aware target query that rejects bulk selection, pending worktrees,
  and competing modal presentations. Sidebar context menus continue to target their explicit row.
- Remove dead Canvas launcher rows when no card is focused, while retaining the Agents entry for profile management.
- Assemble toolbar state once for Normal, Shelf, and Canvas, preserving only the documented `ToolbarContent`
  divergence needed to avoid Canvas relayout animation.
- Remove the notifications style branch and share leading-control metrics between Agents and Bell.
- Restore rename prompt submit/tooltip semantics and advertise the configurable shortcut from the context menu.
- Verify the reported first-focus timing risk at runtime before changing it; do not add speculative focus workarounds.

- Updated 2026-08-17: Grouped the conditional update indicator with Bell in the leading cluster — see [002-notification-update-group.md](002-notification-update-group.md).
