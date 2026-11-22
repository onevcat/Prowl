# 095.014 — M4: diagnostics

## Context

"Why did no notification arrive?" had no answer without a debugger: the Mac kept no result,
the gateway dropped the APNs reason, the phone logged its errors as private data only, and the
Notification Service Extension logged nothing.

## Change

- Gateway (`onevcat/prowl-push-gateway`): a push that fails for a while answers
  `503 {"error":"try-later","reason":<APNs reason>}`; the reason names no device or content.
  Deployed 2026-11-22.
- Contract: `gateway.pushFailures` in `Mirror/Fixtures/push/contract.json` lists failure
  bodies and the reason the Host reads from each. The Host and the gateway test against it.
- Host:
  - `MirrorPushGatewayResult.failed(reason:)`: the gateway's reason, else its error code, else
    `http-<status>`, or `network`. `URLSessionMirrorPushGateway.reason` keeps a short ASCII
    code only (at most 64 characters), since it goes into logs and Settings.
  - `MirrorHost.lastPushes` keeps the last push per device in memory
    (`MirrorPushDelivery`); the sender records every result and logs failures with the reason.
  - Settings shows it under each device's notification state (`MirrorPushDelivery.summary`).
- Phone:
  - `MirrorPushNotification.read` says why a push keeps the fallback text (`malformed`,
    `noKey`, `cannotOpen`, `unsupportedContent`); the extension logs it in the
    `com.onevcat.prowl.mirror-ios` subsystem, category `Push`.
  - `MirrorPushCoordinator` logs its decisions in public text (no APNs token, settings changed
    meanwhile, the Host said the token is gone). Gateway errors hold only status codes and are
    logged in full; other errors stay private.
- User docs: `docs/remote-mirror.md`.

## Decision

The last push result is kept in memory only: no new stored data, and it describes the current
run of the Host.

## Refs

PR: stacked on M3.
