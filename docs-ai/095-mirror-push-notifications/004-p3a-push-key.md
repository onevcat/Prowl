# 095.004 — P3a: push key and content on iOS

## Context

First iOS slice of P3 (see the slice list in [000-plan.md](000-plan.md)). The Notification
Service Extension (P3b) needs the push key of each Host and the rules to open `sealed`; this
slice provides both without a caller yet. No device check is needed.

## Change

- `Mirror/Shared/MirrorPushCrypto.swift` (moved from the Host's `Push/` folder, with
  `MirrorPushKind`): the Host and the iOS app now compile one implementation. Added
  `hostID(ofSealed:)`, `open(_:key:)` (malformed input throws `Failure.malformed`, a wrong
  key or a changed byte throws CryptoKit's authentication failure) and
  `MirrorPushContent.decode(_:)`, which refuses any version other than 1.
- `Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorPushKeyStore.swift`: saves, loads and
  removes the derived key per Host UUID in `$(AppIdentifierPrefix)com.onevcat.prowl.mirror.shared`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the extension can read it while the
  phone is locked.
- `Mirror/iOS/Config/App.entitlements`: `keychain-access-groups` with the app's own group
  first, so credentials saved before (without an explicit group) stay where they are.
  `Config/App-Info.plist` carries the shared group name, because the team prefix is known only
  at build time.
- Tests: `Mirror/iOS/ProwlMirror-iOSTests/MirrorPushTests.swift` (wire vector, wrong key,
  changed byte, malformed values, content version, Keychain round trip on the simulator).

## Refs

PR: #1148 (stacked on #1145).
