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

Reading pane A while pane B blocks (Mac locked by onevcat, PASS):

| Time (UTC) | Event |
| --- | --- |
| 06:01:08 | Mac locked |
| 06:01:41 | Claude Code started in pane B and stopped at its trust prompt (blocked); the phone showed pane A, connected |
| 06:01:41–06:02:09 | No push while the phone stayed connected |
| 06:02:09 | Phone locked (disconnects) |
| 06:02:14 | One push for pane B ("Prowl" / "An agent needs your attention") |

## Refs

PR: P3f (stacked on #1152).
