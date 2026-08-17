# 058.002 — Notification and Update Group

## Context

Moving the notification bell into the leading orchestration cluster left the background-update
indicator in the trailing toolbar. The two related controls no longer read as a group.

## Change

`WorktreeDetailView.AgentNotificationsToolbarContent` now keeps Bell and the conditional
`ToolbarUpdateButton` together immediately after the Agents + Quick Launch group in Normal,
Shelf, and Canvas. The original button views retain their own tint, tooltip, accessibility, and
popover behavior.

Adjacent native navigation groups merge on macOS 26, so the bell/update pair is one isolated
navigation item: it hides the shared toolbar background and owns one outer glass capsule. This
keeps the pair together while retaining the visual gap after Agents. The durable implementation
and review standard live in
[061 Native Toolbar Controls](../061-native-toolbar-controls/toolbar-controls.md).

## Current state

The Command Palette Debug action **[Debug] Simulate Update Found** exposes the update indicator
for visual verification without contacting Sparkle. `docs/components/updates.md` and
`docs/components/notifications.md` describe the current leading toolbar behavior.
