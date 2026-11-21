# 095 — Mirror Push Notifications: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-21 |
| **Primary PRs** | #1142 (plan) |
| **Related** | [096-mirror-remote-access](../096-mirror-remote-access/000-plan.md), [089-mirror-ios-redesign](../089-mirror-ios-redesign/000-plan.md), [091-remote-mirror-alpha-settings](../091-remote-mirror-alpha-settings/000-plan.md), `docs/remote-mirror.md`, `docs/remote-mirror-wire.md` |

## Background

The iOS mirror only knows about an agent while it is in the foreground. iOS suspends the app
soon after it goes to the background (`sessions.suspendAll()` in
`Mirror/iOS/ProwlMirror-iOS/ContentView.swift`), the Host connection ends, and the phone cannot
tell when an agent is blocked or finished. A notification when an agent needs attention is the
main value of a phone client.

A notification for a suspended app needs APNs, so we operate a small push gateway. Push is
**free**. App Review Guideline 4.10 forbids charging for built-in capabilities such as Push
Notifications, so the paid product (Mirror Pro) is remote access through our relays
([096](../096-mirror-remote-access/000-plan.md)). Prowl for Mac stays free and
source-available, with no entitlement check.

## Goals

- **P1** — A paired iPhone or iPad gets a notification when an agent on the Mac becomes
  **blocked** or **done**, while the app is not connected and the user is away from the Mac.
  A tap opens the app on that pane; the app connects and shows the current prompt, if any.
- The notification content is end-to-end encrypted between the Host and the phone. The gateway
  and Apple see only ciphertext and a generic fallback text.
- No traffic from the Mac to the gateway unless the user turned the feature on, on both sides.
- **P2** — A Live Activity with agent counts.

### Non-goals

- Charging for notifications (Guideline 4.10).
- Answering a prompt from the lock screen. The content extension has no pairing credential,
  the payload has no prompt identity that the Host can check later, and the Host releases a
  conversation feed 600 s after the last subscription ends
  (`MirrorHost.conversationFeedRetention`). A tap that opens the pane covers the need.
- Android push (FCM). The design keeps it possible.
- A managed preference (MDM) to turn push off. Deferred.

## Design / Approach

### Parts

| Part | Where | Role |
| --- | --- | --- |
| Push gateway | separate private repository, Cloudflare Workers | Issues push tokens, sends to APNs, rate limits |
| Host push sender | `App/Sources/Features/RemoteMirror/` | Per paired device registration, presence, encryption, sends |
| iOS client | `Mirror/iOS/` | APNs registration, Notification Service Extension, settings, deep link |

### Registration and revocation

One **push token per (device, Host)**. Two kinds of authority are kept apart:

- **Send**: `pushToken`, a random opaque bearer (32 bytes) that the Host holds. It permits
  only `POST /v1/push` and `POST /v1/activity` for that one device.
- **Manage**: only the iOS installation that created the record. The app attests once with
  App Attest (`POST /v1/installations`), and every management request carries an App Attest
  assertion over the request: create a token (`POST /v1/tokens {apnsToken, environment}` →
  `{pushToken}`), change the APNs token, delete a token, register or end a Live Activity.
  A `pushToken` alone cannot change or delete anything.

State on the Host, per paired device (`MirrorPairedDevice` in `MirrorAuthentication.swift`,
new optional fields):

| Field | Set by | Meaning |
| --- | --- | --- |
| `pushToken`, `kinds` | `pushRegister` from the phone | Where to send, and which events (`blocked`, `done`) |
| `pushAllowedByMac` | the Mac user | Persisted; `false` means never send to this device, whatever the phone registers |

| Action | Effect on the Mac | Effect on the gateway |
| --- | --- | --- |
| Mac switch **Send Notifications to Paired Devices** off | Stops all sends at once; registrations kept | None |
| Mac turns a device off | `pushAllowedByMac = false`, persisted; a later `pushRegister` is stored but not used | None |
| Phone turns notifications off (all or one Host) | `pushUnregister` to each online Host → registration removed | `DELETE /v1/tokens/{pushToken}` for each Host, so an offline Host gets `410` on its next send and drops the registration |
| Device unpaired on the Mac | Registration removed with the device | Token expires after 90 days without use |
| App deleted | Next send gets `410` (APNs `Unregistered`) → registration removed | Token marked gone |

`pushRegister` is sent only when the Host advertises the `push-v1` capability; an old Host
closes the connection on an unknown control. The reply carries `pushAllowedByMac` and the Mac
switch state (`pushEnabled`), so the app can say where notifications are turned off.

### Flow

1. The Host listens to agent state changes (`AgentObservationStore.publishAgentChanged`).
2. On `blocked` or `done`, for each device that has a registration, wants the kind, is allowed
   by the Mac, and is not online (`MirrorHost.isOnline(_:)`), and only while the user is away
   (see Presence), it posts `POST /v1/push {pushToken, collapseID, sealed}`.
3. The gateway sends an APNs alert with `mutable-content: 1`, the generic fallback text,
   `apns-collapse-id`, and `sealed` as custom data.
4. The Notification Service Extension opens `sealed`. It always takes the pane for the deep
   link; it shows details only when the user turned on **Show Details** (see Content).

There is no lasting connection from the Mac to the gateway: one HTTPS request per event.

### Outbound traffic gate

The Mac makes **no** request to the gateway unless all are true: Remote Mirror is on and the
Host runs (`MirrorHost.isRunning`); **Send Notifications to Paired Devices** is on (off by
default); a paired device has a registration that the Mac allows. The Mac makes no other
gateway request. Each push request carries only `pushToken`, a collapse ID and ciphertext (Live Activity
requests are listed under P2).
`docs/remote-mirror.md` lists exactly what leaves the Mac.

The gateway stores installation records (App Attest key ID, public key, assertion counter,
creation time) and token records (push token, owning installation, APNs token, environment,
current activity token and its expiry, last use). It keeps no log of events or payloads beyond
rate-limit counters. A leaked `pushToken` can only make one device show the generic text, or
change the counts of an active Live Activity; per-token rate limits and revocation by the
phone bound that.

### Presence

No push while the user sits at the Mac; a timely push once they leave.

- **Present** = screen not locked, display not asleep, keyboard or mouse input in the last
  2 minutes (`CGEventSource.secondsSinceLastEventType`, no permission needed; lock and display
  sleep from system notifications). Anything else is **away**. The monitor runs only while the
  sender has a registration to serve.
- Present: no push. Away: push as events happen.
- Catch-up: the Host keeps, per device, the `blocked` prompt openings that were held back
  (user present, or the device online) and not yet delivered. It checks them at two moments:
  the Mac changes to away, and the device goes offline while the Mac is away. Each opening is
  pushed at most once, and only while it is still `blocked`. Example: the Mac is locked, the
  user reads pane A on the phone, pane B blocks (held back: device online), the user locks
  the phone → the device goes offline → pane B is pushed. `done` is not sent late.
- Debounce: `blocked` once per prompt opening; `done` only after at least 10 s of `working`.
- Collapse ID = truncated HMAC-SHA256 of the pane UUID with the push key.
- Gateway `410` → drop the registration. Network errors → no retry.
- Mac asleep: nothing is sent, and the agents are paused too. Keeping the Mac awake while
  agents work is planned separately.

### Encryption and content

- Key: HKDF-SHA256 over the existing 32-byte device secret, salt = Host UUID, info =
  `prowl-mirror-push-v1`. Cipher: ChaChaPoly. `sealed` = Host UUID + combined box.
- Plaintext: `{v, kind, paneID, title, body, stateChangedAt}`.
- The app stores only the derived push key, in a Keychain group shared with the extension.
- **Content**: by default the notification shows only "An agent needs your attention" or
  "An agent finished" (Guideline 4.5.4, and work environments). **Show Details** (off by
  default) adds the project or tab name and the prompt title. The fallback text is what users
  see when the extension fails, so it reads as a normal notification.

### Mac setting

The **Connect to This Mac** group gets **Send Notifications to Paired Devices** (off by
default). Under it, each paired device shows **On**, **Not set up** ("Turn on notifications
in Prowl Mirror on this device"), or **Off for this device**, with a control to turn it off or
on. The Mac does not know about subscriptions.

### iOS

- Notification Service Extension target in `Mirror/iOS/Project.swift`; shared Keychain group.
- Settings: a global switch, per Host event kinds, **Show Details**.
- Tap → open the Host and pane (connect if needed) and show the current prompt.

### P2 — Live Activity (counts only)

- One activity per Host: working, blocked and done counts and the time of the last change;
  Dynamic Island compact shows the most urgent state color and the blocked count.
- ActivityKit starts an activity only while the app is in the foreground, so the app starts it
  from the foreground (when the user opens the Host, or with a control); verify the exact
  trigger in P4.
- Registration: when it starts an activity, the app tells the Host over the live
  connection (`activityStart {expiresAt}`, at most 8 hours, the ActivityKit limit) and uploads
  the activity push token, and each rotation, to the gateway (a management request). The Host
  never sees the activity token, and the app needs no Host connection after it goes to the
  background.
- Sending: the Host sends `POST /v1/activity {pushToken, counts, changedAt}` only while it has
  an unexpired `activityStart` for that device, and only when a count changes. The gateway
  maps it to the current activity token.
- Stopping: the Host stops at `expiresAt`, after it sends `end` (all agents idle or done for a
  few minutes), when the app sends `activityEnd` (the user ended it in the app), or when the
  gateway answers `404` (the app reported the activity as dismissed or ended, or it has no
  activity token). A dismissal while the app is suspended reaches the gateway when the app
  next runs; until then at most the remaining time to `expiresAt` of count updates can go out.
- Outbound content, separate from the push gate above: these requests carry plaintext counts
  and times with the `pushToken`. They exist only for a device whose user started a Live
  Activity. No titles: the spike showed that the view cannot read the Keychain on a device.
- Updates never alert while the user is present.

## Slices

The gateway lives in a separate private repository; its slices are named G. Prowl PRs P1–P3
form one stack (`gh stack`). Every Prowl PR passes `make check` and `make test`, and updates
`docs/` where behavior changes.

**S0 — real push on a device** (no PR; done 2026-11-21, see Spike results)
- Goal: prove the first notification a user sees.
- Accept: on iPhone One (Debug Mirror build with an NSE prototype, sandbox key), a push
  arrives on the locked screen; the NSE reads the shared Keychain and decrypts; a corrupt
  `sealed` or a missing key shows the generic text.

**G1 — push gateway** (private repository)
- Content: installations with App Attest, tokens, `POST /v1/push` to APNs, rate limits,
  expiry.
- Accept: a valid push reaches APNs sandbox (200); a deleted token gets `410`; a management
  request without a valid assertion is refused (401); a `pushToken` cannot call management
  (403); over the rate limit gets `429`; tokens unused for 90 days expire; no payload or event
  appears in logs.

**P1 — Host registration protocol** (no sends yet)
- Content: `push-v1`, `pushRegister`/`pushUnregister`, registration state on
  `MirrorPairedDevice`, persisted Mac permission, wire documentation.
- Accept (unit tests): registrations survive a restart; a device turned off on the Mac stays
  off after a new `pushRegister`; `pushUnregister` and unpairing remove the registration; a
  client without `push-v1` is unaffected; the reply carries `pushEnabled` and
  `pushAllowedByMac`.

**P2 — Host sender**
- Content: presence monitor, event trigger and debounce, catch-up, encryption, gateway client,
  outbound gate, the Mac switch and device states, outbound list in `docs/remote-mirror.md`.
- Accept (unit tests with a test clock, fake presence and fake gateway): zero gateway calls
  when Remote Mirror is off, the Host stops, the switch is off, no registration exists, or the
  Mac disallows the device; no push while present; a push when away; locking the screen
  counts as away at once; catch-up at the change to away and when the device goes offline,
  once per opening and only while still blocked; `done` only after 10 s of working and never
  late; `410` drops the registration; no retry on network errors; the sealed payload opens
  with a shared test vector; the collapse ID does not contain the pane UUID. Manual: a Debug
  instance with the switch off makes no request to the gateway host (checked with a fake
  gateway); Settings screenshots of the three device states.

**P3 — iOS receiving**
- Content: APNs registration, App Attest, `pushRegister`, NSE, generic text and **Show
  Details**, settings, deep link.
- Accept: unit tests for key derivation (same vector as the Host) and NSE decryption.
  End to end on iPhone One with G1 and a Debug Host: Mac locked, an agent blocks → the
  notification arrives within 10 s; a tap opens that pane with the current prompt; generic
  text unless **Show Details** is on; no push while the user works at the Mac; reading pane A
  on the phone while pane B blocks, then locking the phone → pane B is pushed; turning
  notifications off on the phone stops pushes, also from a Host that was offline at the time.

**P4 — Live Activity** (P2 phase)
- Content: gateway activity mapping, Host `activityStart`/`activityEnd` and stop rules, widget
  extension.
- Accept: the activity starts from the foreground; counts change on the lock screen while the
  app is suspended; after `end`, `expiresAt`, `activityEnd` or a gateway `404`, the Host sends
  no further activity request; activity payloads contain no titles; no alert while present.

## Alternatives & decisions

- **Free push** — chosen (Guideline 4.10). Mirror Pro sells remote access instead (096).
- **APNs key in the app** — rejected: a `.p8` key can push to every user of every team app.
- **Host holds the APNs token** — rejected: an opaque per-Host `pushToken` hides the device
  token, and the phone can revoke one Host without reaching it.
- **Separate Mac permission field** — chosen. Deleting the registration alone let the next
  `pushRegister` undo the Mac user's choice.
- **Answer from the lock screen** — deferred (see Non-goals).
- **Presence instead of the viewed pane** — chosen. `isViewedSurface` checks only window focus,
  so it held pushes back when the user left with Prowl in front.
- **Mac switch off by default** — chosen: the Mac sends the traffic, so the Mac user opts in.
- **Gateway on Cloudflare Workers** — chosen after the S0 spike.
- **Send and manage authority apart** — chosen. The Host holds a send-only token; changes
  need App Attest assertions from the creating installation, so a leaked token cannot
  redirect or delete anything.
- **Catch-up when the device goes offline** — chosen, besides the change to away; otherwise a
  prompt held back while the phone was connected was never sent.
- **Live Activity tokens through the gateway** — chosen; the app is suspended in the
  background, so the Host cannot receive token updates.

## Spike results (2026-11-21)

Throwaway projects only.

| Question | Result |
| --- | --- |
| Worker → APNs over HTTP/2 | Yes: `403 MissingProviderToken` without a token, `403 InvalidProviderToken` with a WebCrypto ES256 JWT from a random key; HTTP/1.1 fails to connect |
| APNs keys | Two keys for topic `com.onevcat.prowl.mirror`, one sandbox only, one production only; each is refused by the other environment. Held outside the repository |
| Live Activity view decrypts a sealed field | Simulator: yes. Device (iPhone 15 Pro Max): Keychain read in the view returns `-25291` (`errSecNotAvailable`) |
| `simctl push` runs the NSE / updates a Live Activity | No / no. Both need real APNs on a device |
| Signing | Device Keychain groups need the `$(AppIdentifierPrefix)` prefix; an App Group must be made in the portal or Xcode first |
| Real APNs to a locked device with the NSE (S0) | Yes. Debug Mirror build with a prototype NSE on iPhone One (iOS 27.2.1), sandbox key, phone locked: a valid `sealed` was decrypted with the key from the shared Keychain group (body ends "[decrypted]"); a corrupt `sealed` and a deleted key (`errSecItemNotFound`) both left the generic text. APNs answered 200 each time |

S0 notes for P3:

- Adding `keychain-access-groups` to the app changes its default Keychain group to the first
  entry. List `$(AppIdentifierPrefix)com.onevcat.prowl.mirror` first, so the existing device
  credentials (saved without an explicit group) stay in the same group.
- Automatic signing turned on the Push capability of the App ID `com.onevcat.prowl.mirror`.
  The NSE was signed with the wildcard team profile; a distribution build needs an explicit
  App ID for it.
- With "Show Previews: When Unlocked" (a common setting), the lock screen shows only a count;
  the decrypted text appears after unlock. The NSE runs at delivery, while the phone is locked.
- If a first build fails after the extension was embedded, the app keeps an unsigned copy and
  the next build fails with "Embedded binary is not signed with the same certificate"; delete
  the built app and build again.

## Open questions

- Gateway code private or public.
- The exact foreground trigger for starting a Live Activity.

## Amendments

- Updated 2026-11-21: push is free (Guideline 4.10), Mirror Pro moved to remote access in
  [096](../096-mirror-remote-access/000-plan.md); registration and revocation state, generic
  default content, tap-to-open instead of lock-screen answers, Live Activity tokens through the
  gateway. From a plan review of #1142.
- Updated 2026-11-21: send-only `pushToken` with App Attest for management, catch-up when the
  device goes offline, Live Activity registration and stop rules. From a second review.
- Updated 2026-11-21: P1 Host registration protocol — see [002-p1-registration.md](002-p1-registration.md)
