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
  - The token record per Host keeps the APNs token and when the gateway last confirmed it.
    (Since the review fixes in [010](010-p3-review-fixes.md), all records are one Keychain item
    `push-tokens` with a revocation queue.) A record older than a day, or for another APNs
    token, is confirmed with `PUT`; a `404` replaces it. Without this, a token the gateway
    deleted after 90 days idle would be registered again on every connection while the Host
    keeps getting `410`.
- `MirrorHostSession` asks once per connection, after the first pane list, and keeps the
  Host's `pushStatus` instead of treating it as an unexpected message.
- DEBUG launch environment `MIRROR_PUSH_DEBUG_ENABLE=1|0` until the settings switch (P3e).

## Device check (2026-11-22, PASS)

Setup: Prowl Debug from this stack (isolated data folder and socket, listening on
`172.20.10.2:7881`), iPhone One paired with it over the phone's own hotspot, notifications on
through the DEBUG switch. After the first connection the Mac showed the device as
**Notifications on**, and the gateway had issued a new `development` token. A real Claude Code
session in a scratch repository stopped at its trust prompt (`osc.blocked.permission`). The
phone was locked, so it was disconnected from the Host.

| Scenario | Result |
| --- | --- |
| User at the Mac, agent blocked from 05:28:49Z | No push from this Host until the Mac locked (about 2.7 minutes) |
| Mac locked at 05:31:31Z (lock state sampled every 2 s) | One push delivered at 05:31:31Z: "Prowl" / "An agent needs your attention", kind `blocked`, the pane's UUID, the Debug Host's UUID |

## Refs

PR: #1151 (stacked on #1150).
