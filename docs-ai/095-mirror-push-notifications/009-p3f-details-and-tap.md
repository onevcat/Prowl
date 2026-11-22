# 095.009 — P3f: Show Details and tap to open

## Context

Last iOS slice of P3. A notification should lead to the agent that needs the user, and users
who do not mind the tab name on the lock screen may want to see which agent it is.

## Change

- **Show Details** (off by default) in **Hosts → Notifications**. The value lives in the
  shared Keychain group (`MirrorPushKeyStore.showsDetails`), where the extension reads it; no
  App Group is needed. With it on, the extension shows the Host's title (tab and worktree) and
  text; an empty title falls back to the generic text.
- Tap: `MirrorNotificationDelegate` (set in `didFinishLaunching`, so a tap that launches the
  app is delivered too) passes the Host and pane from `userInfo` to `MirrorNotificationRouter`.
  `MirrorRootView` selects the Host, starts or retries its roster connection, waits up to the
  connect timeout for the pane list, and opens the pane, which shows the current prompt. A
  pane that is gone leaves the agents list. The selection change that the tap causes keeps the
  opened pane (the usual reset on Host change is skipped once).
- Foreground notifications show as banners.
- User docs: `docs/remote-mirror.md` "Notifications to paired devices".

## Device check (2026-11-22, iPhone One + Debug Host)

A known key was stored for the Debug Host through the DEBUG hook (notifications off, so a
registration could not replace it), and pushes for a real pane of that Host were sent straight
to APNs sandbox.

| Check | Result |
| --- | --- |
| Show Details off | "Prowl" / "An agent needs your attention" in Notification Center |
| Tap that notification (app in the background) | The app opened the pane `p3d-repo / master` of the Debug Host |
| Show Details on | "p3d-repo · master" / "An agent needs your attention" |

Not checked on the device: the plan's "read pane A, pane B blocks, lock the phone → pane B is
pushed" needs the Mac away again. It is the Host's catch-up when the phone disconnects (P2),
covered by the Host's tests.

## Refs

PR: P3f (stacked on #1152).
