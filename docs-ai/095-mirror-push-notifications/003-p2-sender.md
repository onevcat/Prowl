# 095.003 — P2: Host sender

## Context

Second Prowl slice of 095, stacked on P1. The Host sends push events through the gateway
(G1, onevcat/prowl-push-gateway#1, dev Worker `https://prowl-push-dev.onevcat.workers.dev`).

## Change

- `MirrorPushPlanner` (pure): presence, debounce (`done` after ≥ 10 s working, never late),
  one push per `blocked` opening, catch-up at the change to away and when a device goes
  offline while away, latest opening only. A pane that agent detection misses for less than
  30 s and that comes back in the same state continues, so one prompt is not pushed twice.
  The planner survives a stop of the sender; at the next start, an open prompt that was never
  pushed to a device is held for it again.
- `MacPresenceMonitor`: present = screen unlocked, display awake, input in the last 2 minutes
  (`CGEventSource` idle time, lock and screen-sleep notifications, 10 s poll). It runs only
  while the sender is active.
- `MirrorPushCrypto`: HKDF key, `sealed` format, collapse ID, content JSON; shared test vector
  computed independently with Node's crypto.
- `URLSessionMirrorPushGateway`: `POST /v1/push`; `2xx` accepted, `410` token gone, anything
  else dropped. Debug builds default to the dev gateway; Release builds have no default until
  a production gateway exists, and without a gateway the sender never starts. The
  `remoteMirrorPushGatewayURL` default overrides both.
- `MirrorPushSender`: follows the Host and the panes with Observation; active only when Remote
  Mirror is on, the Host runs, the switch is on, and a device has an allowed registration.
  It observes agent states only while active, takes them at activation without events, builds
  each request in its own task outside Observation tracking, and on `410` calls
  `MirrorHost.dropPushRegistration(_:token:)`.
- `GhosttyMirrorPaneSource.pushPaneStates()` reads only agent states (through
  `WorktreeTerminalManager.allWorktreeStates`, without the tab filter), so title changes do
  not wake the sender.
- Settings: **Send notifications to paired devices** in Connect to This Mac; each paired device
  shows its notification state with **Turn Off** / **Turn On**. A device the Mac turned off
  shows that state and **Turn On** even without a registration.
- Docs: `docs/remote-mirror.md` (behavior and what leaves the Mac), `docs/remote-mirror-wire.md`
  (encryption and the gateway call).

## Deviations from the plan

- The `blocked` body is a fixed localized text ("An agent needs your attention"), not the
  prompt title: reading the prompt needs the screen reader of a subscription. Title = tab and
  worktree name.
- The production gateway does not exist yet. Release builds send nothing until it is deployed
  and its URL is set as the Release default (a release blocker for this feature).

## Refs

PR #1145. Tests: `MirrorPushPlannerTests`, `MirrorPushCryptoTests`, two sender tests in
`MirrorHostTests` (one with seven gate cases).
