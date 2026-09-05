# Notifications & Agent Reminders

> How Prowl tells you an agent finished or needs you — system notifications, the
> bell/unread indicators, and Dock badge/bounce.

**Keywords:** notification, agent reminder, bell, unread, command finished, dock badge, dock bounce, sound, alert, finished

**Related:** [agent-detection](agent-detection.md) · [active-agents](active-agents.md) · [terminal](terminal.md) · [settings](settings.md)

## What it is

Prowl watches your panes and surfaces three kinds of alerts so you can leave the
screen and come back exactly when you're needed:

1. **Agent reminders** — when an agent in an unfocused worktree rings the bell or
   emits a desktop notification (e.g. on finishing), Prowl flags that worktree
   (bell/unread) and can notify.
2. **Command-finished notifications** — when a long-running command completes.
3. **Terminal bell / desktop notifications** — bell (BEL) and explicit terminal
   notifications increment unread indicators.

## When a notification fires

**Command finished** posts a notification only when **all** hold:
- `commandFinishedNotificationEnabled` is on,
- the command ran longer than `commandFinishedNotificationThreshold` (default
  **10 s**),
- it wasn't a user-initiated exit (Ctrl-C → exit 130, SIGTERM → 143),
- you didn't type in that pane within the last ~3 seconds.

Custom commands also post a success toast when they exit 0.

Whether these become **macOS system banners** depends on
`systemNotificationsEnabled`; in-app alerts depend on `inAppNotificationsEnabled`.
A standalone sound (`notificationSound` — a picker offering Never, the macOS
system sounds, and the bundled Prowl Classic chime) plays only when system
notifications are **disabled** — when banners are on, the banner carries its own
sound.

## Where unread shows up

- **Sidebar:** an orange bell next to a worktree with unseen notifications.
- **Toolbar:** a bell button follows the Agents control in the leading area in
  Normal, Shelf, and Canvas. When an app update is available, its indicator
  appears in the same control immediately after the bell. The bell badge shows
  the unread count; opening the popover marks items read.
- **Shelf:** orange highlight on the relevant tab slot + a dot on the spine.
- **Canvas:** the card's title bar turns orange.
- **Dock:** an optional numeric badge (count of worktrees with unseen
  notifications).

Unread clears when you **focus** the relevant worktree/surface or view the
notification. `moveNotifiedWorktreeToTop` floats a freshly notified worktree to the
top of its section. **Jump to Latest Unread** (`⌘⌥U`) takes you straight to it.

## Dock behavior

- **Badge:** `showNotificationDotOnDock` shows an unread count on the Dock icon.
  Requires macOS notification permission + "Badge app icon" enabled; Prowl
  disables the toggle if the system doesn't allow it.
- **Bounce:** `dockBounceMode` — `off`, `once` (single bounce), or `continuous`
  (bounces until you bring Prowl forward).

## Settings (Settings → Notifications)

- `inAppNotificationsEnabled` — in-app alerts / bell indicators.
- `systemNotificationsEnabled` — macOS system banners.
- `notificationSound` — which sound to play (`never`, a system sound such as
  `hero`, or `supacodeClassic` = Prowl Classic, the default). Selecting a sound
  previews it. Replaces the legacy `notificationSoundEnabled` toggle (`true` →
  `supacodeClassic`, `false` → `never` on migration).
- `muteNotificationsForActiveSurface` (default on) — skip the banner, sound, and
  dock bounce when the notification comes from the pane you're already looking at
  (selected worktree, focused pane, key + visible window). Sidebar reordering
  still happens. Workflow status-edge notices are worktree-level rather than pane-
  level, so the selected worktree in a key, visible window counts as currently viewed.
- `moveNotifiedWorktreeToTop` — float notified worktree to top.
- `commandFinishedNotificationEnabled` + `commandFinishedNotificationThreshold` —
  long-command notifications and their minimum duration.
- `showNotificationDotOnDock`, `dockBounceMode` — Dock badge & bounce.
- **Agent Island** — an opt-in (`agentIslandEnabled`, default off) top-of-screen projection of
  Active Agents. Settings → Agents → Display selects Automatic placement or a fixed display; see
  [agent-island](agent-island.md).

Full field detail: [`reference/settings-fields.md`](../reference/settings-fields.md).

## Gotchas for agents

- The notification that matters most for human attention pairs with the **Blocked**
  agent state (a prompt waiting on the human) — see
  [agent-detection](agent-detection.md).
- Unread state is **transient** — focusing a worktree clears it; it isn't a
  durable inbox.
