# 095.002 — P1: Host registration protocol

## Context

First Prowl slice of 095. The Host must know, per paired device, where to send push events and
whether the Mac user allows it, before any sending exists (P2).

## Change

- Wire: capability `push-v1`; controls `pushRegister {pushToken, kinds}`, `pushUnregister`,
  and the reply `pushStatus {pushEnabled, pushAllowedByMac, registered}`
  (`MirrorProtocol.swift`, `docs/remote-mirror-wire.md`).
- Model: `MirrorPairedDevice.push` (`MirrorPushRegistration`: token and kinds) and
  `pushAllowedByMac` (`nil` = allowed), stored with the Host identity in the Keychain
  (`MirrorAuthentication.swift`). Unknown kinds are dropped and a broken push field decodes as
  "no registration", so a device record never becomes unreadable.
- Host: `MirrorHost.pushEnabled` (UserDefaults `remoteMirrorPushEnabled`, off by default; the
  Settings control comes in P2), `setPushAllowed(_:for:)`, and handling of the two controls
  for the authenticated device only. A token that is not URL-safe Base64 of 16–256
  characters, or more than 16 kinds, closes the connection. A list with no known kind removes
  the registration. An unchanged registration (same token and kinds), which the phone sends on
  every connection, is not saved again.
- `pushStatus` also goes to the device's open connections when the Mac user changes the switch
  or the device's permission. At most 16 push controls per connection. A failed Keychain save
  of a phone registration is logged and the reply shows the old state; only the Mac user's own
  changes set the Host error. A stored registration with no known kind decodes as none.
- Nothing is sent to the gateway in this slice.

## Refs

PR (this slice). Tests: `MirrorPushRegistrationTests`, five tests in `MirrorHostTests`.
