# 091.003 — Slice 2: Settings groups and the reduced panel

## Context

Slice 2 of the [plan](000-plan.md): move configuration and management from the toolbar
panel to Settings, and name the two directions.

## Change

- `App/Sources/Features/Settings/Views/RemoteMirrorSettingsView.swift` shows, while the
  switch is on, **Connect to This Mac** (status, start and stop, **Start listening when
  Prowl opens**, **Listen on**, **Port**), **Paired Devices** (all devices, revoke, revoke
  all, **Add a Device…**), and **Connect to Another Mac** (saved Macs, **Connect to a
  Mac…**). The Settings window receives `RemoteMirrorStore` through the environment.
- `GlobalSettings.remoteMirrorStartsHostOnLaunch` (default `false`).
  `RemoteMirrorStore.startHostOnLaunchIfNeeded()` runs once from `ProwlApp`.
- The toolbar panel in `App/Sources/Features/RemoteMirror/MirrorHostButton.swift` keeps the
  status, start and stop, **Add a Device…**, the online devices, and a link that sends
  `AppFeature.Action.openRemoteMirrorSettings`.
- Shared pieces moved out of the panel file: `MirrorPairingView.swift`,
  `MirrorDeviceRow.swift` (row, status text, disconnect alert), `MirrorListenOption.swift`.
- `MirrorHost.loadDevicesIfNeeded()` reads the saved devices for Settings before the first
  start. It creates no identity and does nothing while the switch is off.
- The legacy keychain import of saved Macs runs when the Settings section shows with the
  switch on, not on the toolbar click.
- The visible copy says "listening" in place of "Host" in the panel, Settings, and the
  pairing sheet.

## Corrections found on the way

`MirrorHost.revoke(_:)` rebuilt the listener without a check of the run state. On a stopped
Host with a loaded identity, this opened a listener. It now rebuilds only while the Host
runs or starts, as `revokeAllDevices()` already did. Settings makes "revoke while stopped"
a normal path, so the fix ships with this slice.

## Open points

- Error strings from `MirrorHost` still say "Host".
- The pairing sheet still has one page for both device types (slice 3).
