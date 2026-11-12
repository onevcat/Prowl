# 091 — Remote Mirror alpha: Settings tab and visibility: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-11-13 |
| **Primary PRs** | #1084, #1085, #1087 |
| **Related** | [087-mirror-conversation-events](../087-mirror-conversation-events/000-plan.md), [089-mirror-ios-redesign](../089-mirror-ios-redesign/000-plan.md), `docs/remote-mirror.md` |

## Background

Remote Mirror is hidden behind the environment variable `PROWL_REMOTE_MIRROR=1`
(`App/Sources/Support/FeatureFlags.swift`). A user cannot turn it on without a launch
wrapper. The toolbar panel (`App/Sources/Features/RemoteMirror/MirrorHostButton.swift`)
holds everything in one popover: the listener configuration, Host start and stop, pairing,
the full paired-device list with revocation, and the Mac-to-Mac client list. The Host does
not start with the app. The panel uses the implementation words "Host" and "Client", which
the user must translate into "who connects to whom".

The plan is to ship the feature as an alpha for one or two releases, then publish the iOS
Mirror app and move to beta.

## Goals

- Replace the environment variable with a persisted setting that is off by default.
- While the setting is off, no Mirror UI is visible and no listener can run.
- Add a **Remote Mirror** tab in Settings. It holds the alpha switch and, when the switch
  is on, the detailed configuration and management.
- Reduce the toolbar panel to the frequent actions: Host start and stop, new pairing, and
  the devices that are connected now.
- Make the two directions easy to tell apart in the UI.
- Let the Host start with the app (opt-in).

### Non-goals

- No change to the transport, the pairing security, or the iOS app, except one optional
  platform field in the pairing handshake (slice 3).
- No removal of the Mac-to-Mac client.
- No discovery (Bonjour) and no relay configuration UI.

## Design / Approach

### Visibility

`GlobalSettings.remoteMirrorEnabled` (default `false`) replaces `FeatureFlags.remoteMirror`.
`RemoteMirrorStore` reads the setting through `@Shared(.settingsFile)` and exposes
`isEnabled`. All view gates read `isEnabled`. `MirrorHost` takes an `enabled` closure in
place of the constant, so `start()` stays refused while the setting is off. When the
setting changes to off, the store stops the Host and closes all outgoing mirrors. This
keeps the existing security rule: hidden UI never leaves a reachable listener.

The switch controls both directions.

### Settings tab

A top-level **Remote Mirror** section after **Commands**, icon `network`. **Commands**
gets a different icon, because `globe` is too near to the Mirror icon.

- Off: one **Enable Remote Mirror** switch, an Alpha mark, and one sentence that says what
  the feature does.
- On: two groups named by direction, not by role.

| Group | Subtitle | Content |
| --- | --- | --- |
| **Connect to This Mac** | An iPhone or another Mac sees and controls the Prowl terminals on this Mac | Listener status, start and stop, **Start when Prowl opens** (default off), listen address, port, the full paired-device list, revoke, revoke all, **Add a Device…** |
| **Connect to Another Mac** | Mirror the Prowl terminals of another Mac here | Saved Macs (connect, rename, forget), **Connect to a Mac…** |

The words "Host" and "Client" stay in code only.

The listen address and port stay in `UserDefaults`, owned by `MirrorHost`. The legacy
keychain import of saved Macs moves from the toolbar click to the appearance of this tab;
it is still an explicit user action.

### Toolbar panel

The panel covers only **Connect to This Mac**: status, start and stop, **Add a Device…**,
the online devices with their mirrored panes and the disconnect control, and a link to
Settings. Outgoing mirrors stay in the sidebar section.

### Pairing sheet

`MirrorPairingView` moves to its own file, so the panel and Settings share it. A segmented
control selects **iPhone** (QR code) or **Mac** (copy connection details, then paste in the
other Mac's **Connect to Another Mac** group). Each page has one instruction.

The pairing handshake carries an optional platform value. `MirrorPairedDevice` stores it and
the device list shows an iPhone or Mac icon; a record without it shows a generic icon.

### Slices

| Slice | Content |
| --- | --- |
| 1 | Setting in place of the environment variable, tab with the switch only, view gates, stop on disable, new **Commands** icon |
| 2 | Both Settings groups, start with the app, toolbar panel reduction, `MirrorPairingView` extraction |
| 3 | Pairing sheet pages, device platform field and icons |
| 4 | `docs/remote-mirror.md` rewrite, action log |

## Alternatives & decisions

- **Hide Mac-to-Mac** — rejected after a user check. It stays; the cost is the naming work
  above.
- **Group by device type (iPhone / Mac)** — rejected. For the listener, an iPhone and a Mac
  are the same kind of paired device. The real confusion is the direction.
- **"Share This Mac" as the first group title** — replaced with **Connect to This Mac**, so
  the two titles differ only in "This" and "Another".
- **"Prowl" in place of "Mac" in the titles** — rejected. The user thinks about devices, and
  the iOS app already says "Pair with a Mac". The subtitles limit the scope to Prowl
  terminals.
- **Start with the app, default on** — rejected. A user who only connects to another Mac
  would get a listener without a need. The switch is off by default and does not change by
  itself.
- **A dependency client for the Mirror store** — rejected. The store observes
  `@Shared(.settingsFile)` directly; a client would only wrap it.
- **Keep `PROWL_REMOTE_MIRROR` as an override** — rejected. Two switches for one feature
  make the visible state hard to explain.

## Amendments

- Updated 2026-11-13: slice 1, the alpha switch — see [002-slice-1-alpha-switch.md](002-slice-1-alpha-switch.md)
- Updated 2026-11-13: slice 2, Settings groups and the reduced panel — see [003-slice-2-settings-groups.md](003-slice-2-settings-groups.md)
- Updated 2026-11-13: slice 3, pairing pages and the device platform; slice 4 folded into the slices — see [004-slice-3-pairing-pages-and-platform.md](004-slice-3-pairing-pages-and-platform.md)
- Updated 2026-11-13: fixes from the review loop and the end-to-end pass — see [005-review-fixes.md](005-review-fixes.md)
