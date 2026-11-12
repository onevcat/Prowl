# 091 — Remote Mirror alpha: Settings tab and visibility: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-13 | Slice 1: the alpha switch replaces `PROWL_REMOTE_MIRROR`; Settings section with the switch; stop on disable | #1084, [002](002-slice-1-alpha-switch.md) |
| 2026-11-13 | Slice 2: Settings groups, listener start with the app, reduced toolbar panel, `revoke` fix | #1085, [003](003-slice-2-settings-groups.md) |
| 2026-11-13 | Slice 3: pairing sheet pages, optional `platform` in the `pair` control, device icons | #1087, [004](004-slice-3-pairing-pages-and-platform.md) |

## Outcome & current state (as of 2026-11-13)

- Visibility: `GlobalSettings.remoteMirrorEnabled` and `remoteMirrorStartsHostOnLaunch` in
  `App/Sources/Features/Settings/Models/GlobalSettings.swift`, both off by default.
  `RemoteMirrorStore.isEnabled` in `App/Sources/Features/RemoteMirror/RemoteMirrorStore.swift`
  gates every Mirror view; the store stops the listener and closes outgoing mirrors when
  the switch goes off.
- Settings: `App/Sources/Features/Settings/Views/RemoteMirrorSettingsView.swift` with the
  groups **Connect to This Mac**, **Paired Devices**, and **Connect to Another Mac**.
- Toolbar panel: `App/Sources/Features/RemoteMirror/MirrorHostButton.swift`, frequent
  actions only.
- Shared views: `MirrorPairingView.swift`, `MirrorDeviceRow.swift`, and
  `MirrorListenOption.swift` in `App/Sources/Features/RemoteMirror/`.
- Wire: optional `platform` in `MirrorMessage.PairRequest` on Mac and iOS;
  `MirrorDevicePlatform` in `App/Sources/Features/RemoteMirror/MirrorAuthentication.swift`.
- Manual: `docs/remote-mirror.md` and `docs/remote-mirror-wire.md`.

## Deviations from plan

- Slice 4 did not become a PR. Each slice updated `docs/` with its change, and this log
  ships with slice 3.
- The plan did not list the `MirrorHost.revoke(_:)` correction (see 003).
- The visible copy says "listening" for the listener state. The plan only said that "Host"
  and "Client" stay in code.

## Open questions

- No slice had a visual check in a Debug app or a pairing run with a real iPhone at the
  time of its PR. The automated checks were `make build-app`, `make check`, the affected
  Mac test suites, and `make test-mirror-ios-unit`.
- `MirrorHost` error strings and the iOS app still say "Host".
- The Android client sends no `platform`.
- The move from alpha to beta (iOS app release, switch default) is not designed.
