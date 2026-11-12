# 091.004 — Slice 3: pairing pages and the device platform

## Context

Slice 3 of the [plan](000-plan.md). The pairing sheet explained two procedures in one
paragraph, and the device list could not show what kind of device a row is.

## Change

- `App/Sources/Features/RemoteMirror/MirrorPairingView.swift` has a segmented control,
  **iPhone** (default) and **Mac**. The iPhone page shows the QR code; the Mac page shows
  **Copy Connection Details**. The code, its expiry, and the address are on both pages.
- The `pair` control has an optional `platform` string. The Mac client sends `macos`; the
  iOS client sends `ios` or `ipados`. `docs/remote-mirror-wire.md` describes it.
- `MirrorPairedDevice.platform` (`MirrorDevicePlatform?`) stores a known value.
  `MirrorDeviceRow` shows the matching symbol, or a generic one.

## Decisions

- The platform is not part of the pairing proof. It is a display hint only, so a wrong
  value has no security effect, and the proof format stays compatible with older clients.
- An unknown stored value decodes to `nil`, so one bad value cannot make the Host identity
  unreadable.
- The Android client sends no platform for now. It shows with the generic icon.
