# 095.005 — P3b: Notification Service Extension

## Context

Second iOS slice of P3. A push from the gateway carries only `sealed` and a localized fallback
alert; the phone must turn it into the generic text of its kind without showing what the
Host sent (Guideline 4.5.4, work environments).

## Change

- Target `ProwlMirror-iOSNotificationService` (`Mirror/iOS/NotificationService/`), embedded in
  the app. It compiles only `Mirror/Shared/MirrorPushCrypto.swift`, `MirrorPushKeyStore.swift`
  and `MirrorPushNotification.swift`, and reads keys from the shared Keychain group only.
- `MirrorPushNotification` (app and extension): opens `userInfo["sealed"]` with the Host's key;
  on success sets title `MIRROR_PUSH_TITLE` and the body of the kind (`MIRROR_PUSH_BLOCKED`,
  `MIRROR_PUSH_DONE`), groups by Host (`threadIdentifier`), and replaces `sealed` in `userInfo`
  with `hostID`, `paneID` and `kind` for the tap (P3f). The Host's title and body are not shown.
  Any failure leaves the gateway's alert, which iOS localizes from the app's strings.
- `Mirror/iOS/Push/en.lproj/Localizable.strings`, in both bundles: the four push strings.
- APNs registration moved here from P3c: `aps-environment` in the app entitlements,
  `MirrorPushRegistrar` (permission, then the token from the app delegate). No caller yet in
  Release; P3e's switch calls it.
- DEBUG launch environment for device checks: `MIRROR_PUSH_DEBUG_KEY=<Host UUID>:<hex>` saves a
  push key and registers (token on stdout); `MIRROR_PUSH_DEBUG_DELIVERED=1` prints the delivered
  notifications as shown.

## Device check (2026-11-22, iPhone One, iOS 27.2.1)

Phone locked; three pushes sent straight to APNs sandbox (gateway payload, sandbox key), all
`200`. Delivered notifications as read back by the app:

| Sent | Shown |
| --- | --- |
| `blocked` | "Prowl" / "An agent needs your attention", `userInfo` has Host, pane, kind |
| `done` | "Prowl" / "An agent finished" |
| `sealed` with one changed byte | "Prowl" / "An agent on your Mac has an update" (fallback) |

The sealed body text never appeared.

## Refs

PR: #1149 (stacked on #1148).
