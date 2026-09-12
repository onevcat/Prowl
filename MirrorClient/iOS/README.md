# ProwlMirror-iOS
Native iOS mirror client for Prowl, supporting iPhone and iPad

Migrated from `Awhisper/ProwlMirror-iPad` at commit `2b8e237` into this repository.
The source snapshot retains its notices; the original repository and history remain
available separately. The app now uses `com.awhisper.ProwlMirror-iOS`, so it installs
alongside the old app and does not automatically migrate its saved connections.

## Review-aligned experiment

Use the matching Prowl `feat/mobile-mirror` branch, with `PROWL_REMOTE_MIRROR=1` on
Mac. Upgrade both ends together: legacy protocol negotiation, 64-character keys,
and mirror-private submission/state messages have been removed.

On Host, **Start Host → Add a Device** creates a single-use code that expires after
60 seconds. Enter IP, port and the two code halves. Successful pairing stores a
32-byte device credential in Keychain, then reconnects using that credential.
Previously paired Hosts need no code; leave the field blank. Host stop/restart
retains credentials. Host can list and revoke devices; revoked devices must pair
again. An unknown new IP still needs entering manually. Connection editing can
retain a credential while changing an address and verifies the Host identity.

Select an existing pane or use **New Agent Pane** to select a worktree and an
available Host Agent Profile. Host creates a normal background tab through its
public CLI. Models and permissions come from that Profile. There is no separate
AI Control Console. An uncertain creation is not repeated automatically.

**Send** first reads public Host `list`. Detected Agents use `agents dispatch`.
The current Host does not permit structured Shell submission because it cannot
confirm that the Shell input line is empty. The client preserves the draft and
explains the refusal. Host validates the pane lease, readiness, drafts
and IME/editing activity. Claude paste/Enter and Codex hint styling are checked in
the shared Host path. Dispatch success is not Agent completion. Unknown delivery
preserves the draft and queries the original request receipt after reconnect;
commands are never automatically replayed.

## Reading and input

The same native views support iPad and iPhone (iOS 18+). iPad keeps split navigation
and rotation. iPhone initially hides the session list. Each sidebar row has a
close button that unsubscribes without stopping the Host program.

Live text replaces previous text, with local reflow. Frozen code/table detail views
do not refresh with the stream. Large blocks use bounded lazy text rendering.
History reads 200-line pages from a frozen retained snapshot, with a 2 MiB budget.
Each pane keeps separate live/history reading positions. Erased transient output
is not archived. Ghostty is not embedded in this client.

The composer is one line when unfocused, expands while editing, then scrolls at its
height limit. Send is explicit; Return inserts a newline. Two physical Returns
within 350 ms send when enabled, removing only the shortcut's first newline.
IME composition, editing/selection changes and lost focus cancel the gesture.
Pending or unknown delivery prevents another Send. A changed draft is never cleared
by an older receipt.

Disconnect, Host stop, pane closure, takeover and incompatibility retain the last
output with a red reason. Retry/foreground recovery do not take over another device;
Take Over is explicit. Editing a connection never silently creates a new pane.

## Build and tests

Open `MirrorClient/iOS/ProwlMirror-iOS.xcodeproj` from the Prowl repository. Simulator signing stays
enabled for Keychain tests. Unit tests cover wire vectors, native TLS transport,
command correlation/routing, reading and keyboard behavior. The Host's real App
target covers pairing, revocation, terminal capture and input protection; there is
no copied Host implementation in this client's tests.

DEBUG-only `--mirror-ui-fixture` and `--mirror-ui-launch-fixture` supply deterministic
UI data without connecting to Host or starting an Agent. Component and socket tests
are separate from real Agent/cross-device acceptance.

See the shared [wire contract](../../docs/remote-mirror-wire.md) and
`ThirdPartyNotices/` for source/license notices.
