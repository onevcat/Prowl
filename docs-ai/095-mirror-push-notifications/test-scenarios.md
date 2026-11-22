# 095 — Mirror push: scenarios and how to check them

Living document. Keep it current when a scenario, a test, or the contract changes.

## Run everything

```sh
scripts/test-mirror-push.sh          # Host + iOS app (+ gateway when ../prowl-push-gateway exists)
```

The script runs every push suite of the Host (macOS), the iOS app (simulator) and the gateway
(`npm test`), and fails when the gateway's copy of the contract differs from this repository's.

## The shared contract

`Mirror/Fixtures/push/contract.json` is the one place that states what the three codebases must
agree on:
- the `push-v1` capability and kinds;
- the `pushRegister`/`pushUnregister`/`pushStatus` JSON;
- the encryption vector and the content JSON;
- the gateway address, push request, push statuses and push token format;
- the APNs payload and its fallback localization keys;
- the management headers and the `401` codes that the phone's recovery reads.

| Codebase | Test against the contract |
| --- | --- |
| Host | `App/Tests/RemoteMirror/MirrorPushContractTests.swift` |
| iOS app | `Mirror/iOS/ProwlMirror-iOSTests/MirrorPushContractTests.swift` |
| Gateway (`onevcat/prowl-push-gateway`) | "shared contract" tests in `test/gateway.test.ts`, against the copy `test/fixtures/prowl-push-contract.json` |

What the Host and the app compile from one source is in `Mirror/Shared/`:
- `MirrorPushContract.swift`: capability, gateway URL, and the push control payloads;
- `MirrorPushCrypto.swift`: key, seal, open, collapse ID, kinds and content.

The rule for a change: edit the shared source or the contract file first, then make the three
contract tests pass. A change to the contract file must be copied to the gateway repository.

## Scenarios

| # | Scenario | Tests |
| --- | --- | --- |
| 1 | Notifications on, the phone connects: key saved, token created, `pushRegister` sent, Host answers `pushStatus` | iOS `firstConnectionSavesTheKeyCreatesATokenAndRegisters`, `registersForPushOncePerConnectionAndKeepsTheHostsAnswer`; Host `pushRegistrationPersistsAndTheMacChoiceSurvivesANewRegistration` |
| 2 | User at the Mac: no push | Host planner `blockedWhilePresentIsHeldAndSentOnceWhenTheUserLeaves`; `aGateClosedAfterAPushWasQueuedStopsTheRequest` |
| 3 | User leaves the Mac: one catch-up push per prompt opening, no duplicate | Host planner (same as 2); `aGateClosedAfterAPushWasQueuedStopsTheRequest` |
| 4 | Phone connected: push held; phone disconnects: sent once | Host `aPromptHeldWhileThePhoneIsConnectedIsSentOnceItDisconnects`; planner `blockedWhileTheDeviceIsOnlineIsSentWhenItGoesOfflineWhileAway` |
| 5 | `done` only for a finished turn after ≥ 10 s of work | Host planner `doneNeedsTenSecondsOfWorkingAndTheUserAway`, `anIdleWithoutAFinishedTurnIsNotDone`; `PaneAgentStateCompletedTurnTests` |
| 6 | Mac switch off, or the device turned off on the Mac: no request | Host `pushSenderContactsTheGatewayOnlyWhenEveryGateIsOpen`, `aGateClosedAfterAPushWasQueuedStopsTheRequest` |
| 7 | Phone turns notifications off: `pushUnregister` to connected Hosts, every token deleted (offline Hosts too), no other gateway request | iOS `turningOffDeletesTheTokenOfEveryHostAndSendsNothingElse`, `settingsChangesReachTheConnectedHost`, `turningOffWhileWaitingForAPNsContactsNoGateway`, `aQueuedRequestDoesNotLeaveAfterTurningOff`, `turningOffWhileAttestingStartsNoFurtherRequest` |
| 8 | Forget one pairing of a Mac paired at two addresses: only its token goes | iOS `anotherPairingOfTheSameHostTakesOverAndForgettingTheOldOneKeepsIt`, `forgettingAPairingStopsItsRegistrationWithoutTouchingTheOwner`, `aFailedDeletionIsRetriedAfterARestartEvenForAForgottenHost` |
| 9 | Tap a notification: the pane opens; a closed pane shows the list | iOS `MirrorNotificationOpenerTests` (`opensThePaneOnceTheHostListsIt`, `aPaneThatIsGoneLeavesTheAgentsList`, `aNewerTapTakesOverWhileConnecting`), `opensTheConnectedAddressOfAHostPairedTwice`, `onlyTheLatestTapIsCleared` |
| 10 | Show Details off: generic text; on: tab and worktree name | iOS `showsGenericTextByKindAndKeepsTheRouteForTheTap`, `showDetailsUsesTheHostsTitleAndText`, `theGatewayPayloadOpensAndItsFallbackKeysExist` |
| 11 | The gateway answers `410`: the Host drops the registration; the phone replaces a dead token | Host `pushSenderDropsARegistrationThatTheGatewayNoLongerKnows`, `aLateTokenGoneForAnOldTokenKeepsTheNewRegistrationAndItsPrompts`, `aTokenTheGatewayNoLongerKnowsIsRefusedUntilTheDeviceRegistersAnother`; iOS `aTokenTheGatewayDeletedIsReplaced`, `aTokenTheHostCallsGoneIsReplacedOncePerConnection` |

## On a device (manual, before a release)

There is no device script: it would depend on Zeptap, real APNs and App Attest, and would
drift. Before a release, with a TestFlight build and a release Mac:
1. Turn notifications on; the Mac's device row shows **Notifications on**.
2. Lock the Mac while an agent waits: one notification arrives; none while you work at the
   Mac.
3. Tap it: the pane opens.
4. Turn notifications off on the phone: the Mac shows **Not set up**.

Recipes for an isolated Debug Host with the phone: the memory notes of the 2026-11-22 P3
checks and the slice records `005`–`009`.

## Known gaps and follow-ups

From the architecture review after the stack review (2026-11-22). Slices M1–M4 in the plan address them; each slice removes its item here.
- **`remoteMirrorPushGatewayURL`** (Mac) is for tests with a fake gateway only. Tokens from the real gateway are unknown elsewhere, so the Host would drop every registration.
