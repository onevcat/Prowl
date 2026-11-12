# 091.005 — Review fixes

## Context

A review loop on the stack (#1084, #1085, #1087) and an end-to-end pass in a Debug app.
This file records the findings that changed code.

## Change

| Finding | Problem | Correction |
| --- | --- | --- |
| R1 | The listen address and port were saved only when a listener became ready. An edit in Settings followed by a quit was lost, and a start at launch could use a wider address than the one shown. | `MirrorHost.address` and `MirrorHost.port` save each valid edit to `UserDefaults`. An invalid value does not replace the saved one. |
| R2 | A failed read of the saved devices showed **No paired devices.** | `MirrorHost.deviceListError` holds the failure. Settings shows it with **Try Again**, which reads again without a listener start. A missing identity is still an empty list. |
| R3 | The connection sheet moved to Settings, but the mirror shows in the main window. With that window behind, minimized, or closed, a successful connection showed nothing. | `RemoteMirrorStore.add` calls `showSelectedMirror`, which `ProwlApp` sets to `NSApplication.surfaceMainWindow()`. Cancel does not call it. |

## Found in the end-to-end pass

| Item | Problem | Correction |
| --- | --- | --- |
| E1 | The **Connect to Another Mac** subtitle said "in this window", which is wrong in the Settings window. | New subtitle: "See and control the Prowl terminals of another Mac from this Mac." |
| E2 | The connection sheet, the listener errors, and the saved-Macs notice still said "Host" or named the removed **Connect to a New Host** button. | The sheet title is **Connect to a Mac**; the copy says "the other Mac" and "listening". Strings in the mirror pane and protocol errors keep "Host". |
| E3 | The mirrored-pane rows of a device started at the icon, not under the device name. | The rows have the leading inset of the icon column. |
| E4 | Mirror Host tests used `UserDefaults.standard`. With R1, each test endpoint edit changed the Debug app's own listener settings. | The tests use the suite `UserDefaults.mirrorTests`. |
