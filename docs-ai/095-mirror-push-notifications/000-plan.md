# 095 — Mirror Push Notifications and Mirror Pro: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-21 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [089-mirror-ios-redesign](../089-mirror-ios-redesign/000-plan.md), [091-remote-mirror-alpha-settings](../091-remote-mirror-alpha-settings/000-plan.md), [087-mirror-conversation-events](../087-mirror-conversation-events/000-plan.md), `docs/remote-mirror.md`, `docs/remote-mirror-wire.md` |

## Background

The iOS mirror only knows about an agent while it is in the foreground. iOS suspends the app
soon after it goes to the background, the Host connection ends after eight seconds without
traffic, and the phone cannot tell when an agent is blocked or finished. The user must open the
app and check. A notification when an agent needs attention is the main value of a phone
client.

A notification for a suspended app needs APNs. APNs needs a provider key of the Apple
developer team and the bundle ID of the app. That makes this the first Mirror feature that
needs a service that we operate, and it is also the paid feature of the App Store build
(**Mirror Pro**).

Licensing boundary: Prowl for Mac stays free and source-available, with no paid feature and no
license check. The Mac Host gets a generic outbound "push target" sender that works the same
for every user. Only the iOS app (MIT) and the push gateway (our service) know about the
subscription.

## Goals

- **P1** — A paired iPhone or iPad gets a notification when an agent on the Mac becomes
  **blocked** or **done**, while the app is not connected. A tap opens that pane.
- The notification content is end-to-end encrypted between the Host and the phone. The gateway
  and Apple see only ciphertext and a generic fallback text.
- The gateway sends only for devices with an active Mirror Pro entitlement (trial included).
- **P2** — Answer a blocked prompt from the notification. Show agent state in a Live Activity.

### Non-goals

- A hosted relay for remote access outside the LAN. It is a later paid add-on (separate
  entry). Until then, answering from a notification needs the same reachability as the app
  (LAN, Tailscale or similar).
- Metered pricing (per notification or per session). We sell the capability.
- Android push (FCM). The design keeps it possible; it is not in scope.
- Any paid feature or entitlement check in the Mac app.

## Design / Approach

### Parts

| Part | Where | Role |
| --- | --- | --- |
| Push gateway | separate private repository | Registers devices, checks entitlement, sends to APNs |
| Host push sender | `App/Sources/Features/RemoteMirror/` | Stores one push target per paired device, encrypts and posts events |
| iOS client | `Mirror/iOS/` | APNs registration, Notification Service Extension, paywall, settings |
| RevenueCat | external | Subscription state for the app and the gateway |

### Flow

1. The iOS app gets its APNs token and registers it with the gateway:
   `POST /v1/devices {apnsToken, environment, appUserID}` → `{pushToken}`. `pushToken` is a
   random opaque bearer (32 bytes) that can push to that one device only. `appUserID` is an
   anonymous UUID that the app also gives to RevenueCat.
2. While connected, the app sends `pushToken` to each Host on a new control message
   `pushRegister`, only when the Host advertises the `push-v1` capability in `panes`.
   The message carries the event kinds the user wants (`blocked`, `done`). The app sends it
   again on every connection, so a rotated token or a changed setting reaches the Host.
3. The Host stores the target on the paired device record (`MirrorPairedDevice` in
   `MirrorAuthentication.swift`, new optional field). Revoking the device removes it.
4. The Host listens to agent state changes (`AgentObservationStore.publishAgentChanged`
   publishes `.changed(ActiveAgentEntry)`). On a transition to `blocked` or `done` it posts
   `POST /v1/push {pushToken, collapseID, sealed}` for each device that has a target, wants
   that kind, and is not online (`MirrorHost.isOnline(_:)`), subject to the outbound traffic
   gate below.
5. The gateway checks the entitlement of the device's `appUserID` (cached, refreshed by
   RevenueCat webhooks). If active, it sends an APNs alert with `mutable-content: 1`, a
   generic localized fallback text, `apns-collapse-id` per pane, and `sealed` as custom data.
6. The Notification Service Extension opens `sealed` and sets the real title and body. If it
   fails, the fallback text stays.

There is no lasting connection from the Mac to the gateway. The Host makes one HTTPS request
per event, only when a paired device has a target.

### Encryption

- Key: HKDF-SHA256 over the existing 32-byte device secret, salt = Host UUID, info =
  `prowl-mirror-push-v1`. Both sides already hold the secret, so no new key exchange is needed.
- Cipher: ChaChaPoly (CryptoKit). `sealed` = Host UUID + combined box (nonce, ciphertext, tag).
  The Host UUID is in clear so the extension can choose the key.
- Plaintext JSON: `{v, kind, paneID, title, body, stateChangedAt}`. Title is the tab or
  worktree name; body is the prompt title for `blocked`, or "Finished" for `done`.
- The app stores only the derived push key, in a Keychain access group shared with the
  extension. The device secret stays in the app's own group
  (`Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorAuthentication.swift`).

### Outbound traffic gate

Some users work in companies that watch outbound traffic. The Mac makes **no** request to the
gateway unless all of these are true:

1. **Remote Mirror** is on in Settings (`remoteMirrorEnabled`) and the Host runs
   (`MirrorHost.isRunning`). Turning either off stops all sends at once.
2. A paired device has a push target. The iOS app sends `pushRegister` only while it has an
   active Mirror Pro entitlement and the user has turned notifications on. Without Pro, no
   target exists and the Mac sends nothing.

The Mac makes no other gateway request: no health check, no prefetch, no registration of its
own. Each request carries only `pushToken`, a collapse ID, and ciphertext. `docs/remote-mirror.md`
lists exactly what leaves the Mac.

### Host rules

- Debounce per pane: send `blocked` once per prompt opening, `done` only after a `working`
  period of at least 10 s. A newer event on the same pane replaces the older one.
- Collapse ID = truncated HMAC-SHA256 of the pane UUID with the push key, so the gateway does
  not see pane IDs.
- Skip a pane the user looks at on the active Mac (same rule as
  `muteNotificationsForActiveSurface`).
- Gateway `410` (token gone) or `402` (no entitlement) → drop the target. After a subscription
  ends, at most one request per device goes out; the next `pushRegister` from an entitled app
  adds the target again. Network errors → no retry; a lost notification is acceptable.
- Gateway base URL: a constant, with a `UserDefaults` override for development and for people
  who build their own iOS app and run their own gateway.
- **Remote Mirror** settings show per device whether notifications are on, and the Mac user
  can turn them off for that device (drops the target).

### iOS

- New targets in `Mirror/iOS/Project.swift`: Notification Service Extension (P1); Notification
  Content Extension and Widget Extension for Live Activities (P2). App Group and shared
  Keychain group.
- Paywall with RevenueCat: monthly and yearly product with a free trial (prices are open).
  Restore purchases. No account.
- Settings per Host: event kinds; a global switch.
- Tap → open the Host and pane from `paneID` (connect if needed).

### P2

- **Answer from the notification**: the content extension shows the prompt choices (from the
  sealed payload). A choice opens a short connection to the Host and sends the existing
  `promptRespond` command. All Host safety checks still apply (`PROMPT_CLOSED`,
  `PROMPT_CHANGED`, …). The extension shows the result. If the Host is not reachable, it
  says so and offers to open the app.
- **Live Activity**: one activity per Host that shows the counts of working, blocked and done
  agents.
  - Lock screen: Host name, the three counts, the time of the last change, **Open**, and
    **Answer** while an agent is blocked. Dynamic Island compact: a glyph in the most urgent
    state color (blocked > working > done) and the blocked count; expanded: the lock screen
    content. Colors follow the Mac status colors.
  - The app starts the activity locally when a Pro user leaves the app while agents work or
    are blocked. Attributes (Host name, Host UUID) are set at that start and never travel
    through the gateway. No push-to-start, because its attributes would be plaintext.
  - The Host sends an update through the gateway only when a count changes: high priority for
    a new `blocked`, low priority otherwise. When all agents are idle or done for a few
    minutes, it sends `end` and the final state stays on the lock screen for a short time.
  - The update payload is plaintext to the gateway and Apple, so the default content is only
    counts, states and times. **Answer** targets the first blocked pane through a slot ID (the
    same HMAC as the collapse ID) that the app maps back to a known pane.
  - If the widget extension can decrypt a sealed field at render time, titles and the prompt
    text can be shown too (see Spike results).

## Slices

| Slice | Content |
| --- | --- |
| S0 | Spike: gateway platform can send HTTP/2 to APNs; App Store Connect products; RevenueCat project and webhook |
| S1 | Gateway: device registration, push, entitlement cache, rate limits, delete |
| S2 | Host: `push-v1` capability, `pushRegister`, target storage, event trigger, encryption, settings row, wire and feature docs |
| S3 | iOS: APNs registration, Service Extension, paywall, settings, tap to open |
| S4 (P2) | Answer from the notification |
| S5 (P2) | Live Activity |

## Alternatives & decisions

- **Ship the APNs key in the app** — rejected. A `.p8` provider key can push to every user of
  every app of the team. In the source-available Mac app it would be public, and the
  subscription could not be enforced.
- **Gate by session count** — rejected. The Mirror shows panes that already exist on the Mac;
  a count limit is artificial, and a client-side limit has no server value behind it.
- **Charge per notification** — rejected. Metering makes every notification feel like a cost.
- **Host holds the APNs token** — rejected. With an opaque `pushToken`, the Host cannot see the
  device token or the user ID, and the gateway can revoke a token alone.
- **RevenueCat vs. own StoreKit 2 validation** — recommended RevenueCat (pending confirmation).
  The gateway must check entitlement on every push anyway. RevenueCat gives it a REST lookup
  and webhooks, and handles renewal, grace period, refunds, trials and a later Google Play
  build. It is free below $2,500 monthly tracked revenue. Own validation means App Store Server
  Notifications v2 and JWS chain checks in the gateway.
- **New control message vs. command envelope** — control message `pushRegister`, gated by the
  `push-v1` capability. It is not a CLI command, and an old Host closes the connection on an
  unknown control, so the client must check the capability first.

## Open questions

- Gateway platform: Cloudflare Workers is preferred, but it is not verified that a Worker can
  reach APNs over HTTP/2. Verify in S0; otherwise use a small server (for example Swift with
  APNSwift).
- Prices, trial length, and whether to offer a lifetime purchase.
- Whether the gateway code stays private or is published for self-hosting.

## Amendments
