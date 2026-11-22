# 095.011 — M1: token ledger and settings

## Context

`MirrorPushCoordinator` held four things: the user's settings, the token bookkeeping, the
tickets that stop stale work, and the orchestration of the gateway and the Hosts. Every rule
about tokens could only be tested through the whole coordinator with a fake gateway, App
Attest and APNs. P4 adds activity tokens, so the bookkeeping must be easy to change alone.

## Change

No behavior change.

- `MirrorPushTokenLedger` (`Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorPushTokenLedger.swift`)
  replaces `MirrorPushTokenState`. It is a pure value type with the same Codable shape, so the
  Keychain record `push-tokens` of earlier builds still loads. It owns each bookkeeping rule:
  which token a pairing and build may use, freshness (`MirrorPushTokenRecord.isFresh`,
  `checkInterval`), revoke, retire, drop, confirm, commit, abandon and deleted. Each change
  that is based on a token does nothing when the Host's token was replaced meanwhile.
- `MirrorPushSettings` (`Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorPushSettings.swift`)
  holds the switch, Show Details and the kinds per Host, with their storage. Views read
  `MirrorPushCoordinator.settings`. The switch and the kinds still change through the
  coordinator, because those changes revoke tokens; Show Details changes on the settings.
- `MirrorPushCoordinator` keeps the tickets, the Host queues and the deletion drain, and saves
  the ledger only when it changed.
- Tests: `MirrorPushTokenLedgerTests` (8 tests, including the stored shape of earlier builds);
  the coordinator tests are unchanged apart from the setup. `scripts/test-mirror-push.sh` runs
  the new suite.

## Refs

PR: see the stack after #1154.
