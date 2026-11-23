# 095.008 — P3e: notification settings on the phone

## Context

Fifth iOS slice of P3. The user needs one place to turn notifications on and off, choose the
events per Host, and see why a Host does not notify. Turning off must also stop a Host that is
offline at that moment.

## Change

- **Hosts → Notifications** (`Mirror/iOS/ProwlMirror-iOS/Features/Hosts/MirrorNotificationSettings.swift`):
  the switch, one row per paired Host with its state, and a page per Host with **An agent
  needs you** / **An agent finished**. The footer says when iOS permission is denied.
- `MirrorPushCoordinator`: the switch and the kinds per Host are stored in `UserDefaults` and
  observed by the views. A Host with no kinds left gets `pushUnregister`, and its token is
  deleted at once. `removeRegistration` deletes the Host's token at the gateway and its push
  key; an unreachable gateway keeps the record so that a later call tries again.
- `MirrorHostSession.pushSettingsChanged`: a connected Host with `push-v1` registers again with
  the new kinds, or gets `pushUnregister` when the switch is off; Hosts without `push-v1` get
  nothing (they close on unknown controls). `supportsPush` lets the settings say **Update Prowl
  on the Mac** for such Hosts.
- Turning off: the switch flips, connected Hosts get `pushUnregister`, then every Host's token
  is deleted. Forgetting a Host deletes its token too.
- User docs: `docs/remote-mirror.md` "Notifications to paired devices".

## Device check (2026-11-22, iPhone One + Debug Host, PASS)

| Action | Phone | Mac device row | Gateway tokens |
| --- | --- | --- | --- |
| Open Hosts | Switch on; Debug Host **On** | Notifications on | 2 |
| Turn the switch off | — | Notifications not set up | 1 (the Debug Host's token deleted) |
| Turn it on again | — | Notifications on | 2 |

The per-Host page showed both events on and "The Host notifies this phone while you are away
from the Mac."

## Refs

PR: #1152 (stacked on #1151).
