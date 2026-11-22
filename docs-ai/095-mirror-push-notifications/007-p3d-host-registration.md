# 095.007 — P3d: register with each Host

## Context

Fourth iOS slice of P3. With notifications on, the phone must give each Host a push token
on every connection, so the Host's P2 sender can reach it.

## Change

- iOS protocol: `pushRegister`, `pushUnregister`, `pushStatus`, with the Host's case and field
  names (both sides use synthesized `Codable`).
- `MirrorPushCoordinator` (`Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorPushCoordinator.swift`):
  when notifications are on (`mirrorPushEnabled`) and the Host lists `push-v1`, it saves the
  Host's push key (P3a), gets an APNs token (P3b), and a push token per Host (P3c), then
  returns `pushRegister` with `blocked` and `done`. Nothing is stored or sent while off.
  - The token record per Host (Keychain account `push-token:<Host UUID>`) keeps the APNs token
    and when the gateway last confirmed it. A record older than a day, or for another APNs
    token, is confirmed with `PUT`; a `404` replaces it. Without this, a token the gateway
    deleted after 90 days idle would be registered again on every connection while the Host
    keeps getting `410`.
- `MirrorHostSession` asks once per connection, after the first pane list, and keeps the
  Host's `pushStatus` instead of treating it as an unexpected message.
- DEBUG launch environment `MIRROR_PUSH_DEBUG_ENABLE=1|0` until the settings switch (P3e).

## Device check

Pending: Debug Host from this stack, iPhone One paired with it, Mac away, a blocked agent →
notification within 10 s; none while the user is at the Mac.

## Refs

PR: P3d (stacked on #1150).
