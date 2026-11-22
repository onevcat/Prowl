# 095.013 — M3: dead tokens

## Context

The phone registers its stored push token on every connection and asks the gateway about it
only once a day (`MirrorPushTokenRecord.checkInterval`), so that connections do not contact
the gateway. When the gateway deleted a token (`410`: unknown token, or APNs said the device
token is invalid), the Host dropped the registration, but the phone usually was not connected
to hear it. On its next connection it registered the same dead token again, the Host saved it
and answered `registered: true`, and both sides showed notifications as on. Pushes failed for
up to a day, until the daily check replaced the token.

## Change

- Wire: `pushStatus` gets an optional `tokenGone: true`. It is absent in every other reply.
  Phones before this change ignore it and keep the old behavior (up to a day).
- Host (`App/Sources/Features/RemoteMirror/MirrorHost.swift`): `dropPushRegistration` keeps
  the dropped token per device in memory and sends `pushStatus` with `tokenGone` to the
  device's connections. A `pushRegister` with that token is not saved and gets the same reply;
  another token clears it. After a Host restart, one more push gets `410` and sets it again.
- Phone (`MirrorHostSession`): on `tokenGone` for the token that this connection registered,
  the coordinator forgets the token without a gateway deletion (`MirrorPushCoordinator.tokenGone`,
  `MirrorPushTokenLedger.drop`), and the session registers again, which creates a new token.
  At most once per connection, so that a Host that keeps refusing cannot make a loop. The phone
  contacts the gateway only when the Host said the token is gone.
- Contract: `pushStatusTokenGone` in `Mirror/Fixtures/push/contract.json` (also the gateway's
  copy); wire docs in `docs/remote-mirror-wire.md`.
- Tests: Host `aTokenTheGatewayNoLongerKnowsIsRefusedUntilTheDeviceRegistersAnother` (fails
  without the Host change); iOS `aTokenTheHostCallsGoneIsReplacedOncePerConnection`; both
  contract tests.

## Refs

PR: stacked on M2.
