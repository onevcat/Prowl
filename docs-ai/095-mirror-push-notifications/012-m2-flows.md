# 095.012 — M2: flows out of views

## Context

Three push flows lived in SwiftUI views, where no test reached them: the tap flow in
`MirrorRootView` (with a polling loop), the forget order in `HostsView`, and the order of a
settings change in `MirrorNotificationsSection`. The phone's settings also showed one row per
pairing, so a Mac paired at two addresses had two rows that changed the same kinds.

## Change

- `MirrorNotificationOpener` (`Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorNotificationOpener.swift`)
  runs the tap flow and returns an outcome: `unchanged`, `agents` or `pane(route)`. The root
  view only closes sheets, selects the Host and applies the outcome.
- `MirrorHostSession.settled()` waits through Observation until the connection is no longer
  connecting (ready, failed, also after the connect timeout, or stopped). It replaces the
  200 ms polling loop.
- `MirrorHostSessions` owns the order of push changes:
  - `forgetPairing(_:)` reads the pairing's device ID before the store deletes the credential,
    deletes the push token, and closes the connection;
  - `setNotificationsEnabled(_:)` and `setNotificationKinds(_:for:)` change the setting first,
    then tell the connected addresses of the Mac;
  - `supportsPush(hostID:)` answers from any connected address of the Mac.
- Hosts → Notifications lists each Mac once (`MirrorNotificationsSection.macs`), named after
  the entry that a tap would open. `MirrorNotificationRouter.entry` takes a Host UUID.
- Tests: `MirrorNotificationOpenerTests` (5) and
  `forgettingAPairingDeletesItsTokenAndClosesItsConnection`. User docs: `docs/remote-mirror.md`.

## Refs

PR: stacked on M1.
