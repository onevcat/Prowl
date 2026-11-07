# ProwlMirror-iOS
Native iOS mirror client for Prowl, supporting iPhone and iPad

Migrated from `Awhisper/ProwlMirror-iPad` at commit `2b8e237` into this repository.
The source snapshot retains its notices; the original repository and history remain
available separately. The app now uses `com.onevcat.prowl.mirror`, so it installs
alongside the old app and does not automatically migrate its saved connections.

## Flow

Use a Prowl Host built from the same revision (or a matching Prowl release), with
`PROWL_REMOTE_MIRROR=1` on Mac. Upgrade both ends together: legacy protocol negotiation, 64-character keys,
and mirror-private submission/state messages have been removed.

The app has three levels (docs-ai 088):

1. **Hosts** lists the paired Macs. **Add Host** takes the address, port and the two
   halves of the 60-second code from **Start Host → Add a Device** on the Mac, or scans
   its QR code. Successful pairing stores a 32-byte device credential in Keychain and the
   Host in `UserDefaults`; a saved Host reconnects without a code. **Rename** changes the
   name shown on the phone; **Forget** removes the entry and its credential. A Host that
   revoked the device fails to connect and needs a new pairing through **Add Host**.
2. **Panes** of one Host, grouped by project, each with its agent badge, a state dot
   (working, idle, needs you, shell) and whether the Host serves its conversation. The
   roster refreshes every three seconds while the app is active. **New Agent Pane**
   selects a worktree and an available Agent Profile; the Host creates a normal
   background tab through its public CLI and the new pane opens.
3. **Pane**: a chat over `conversation-v1` when the Host serves the pane's conversation,
   the terminal screen (`text-v1`) otherwise. The Chat | Screen control switches on the
   same connection. A Screen pane whose agent starts moves to Chat by itself unless you
   chose Screen; a Host that stops serving the conversation falls back to Screen. The
   **…** menu holds History / Live Output (screen), Reconnect or Take Over, and
   Disconnect. Leaving the pane closes its connection; the Host session keeps listing.

iPhone and iPad use the same stack navigation (iOS 26+).

## Chat

Chat renders the Host's normalized events (see the [wire contract](../../docs/remote-mirror-wire.md#conversation-stream-conversation-v1)):
your messages on the right with their origin (queued, automation) and time, the agent's
Markdown on the left, reasoning summaries, tool cards (collapsed to a title and status;
expand for the command or path, the diff and the bounded output), prompt cards with the
question and its choices and a note to answer on the Mac, attention rows while the agent
is blocked, session dividers, compaction marks, subagent and notice rows. Tool start and
end merge into one card; a queued message disappears when the agent takes it. The view
follows the newest message until you scroll up; **Latest** returns to it. The store keeps
the last 2000 events and resumes by sequence after a reconnect; a gap shows a note.

## Screen and input

Live text replaces previous text, with local reflow. Frozen code/table detail views
do not refresh with the stream. Large blocks use bounded lazy text rendering.
History reads 200-line pages from a frozen retained snapshot, with a 2 MiB budget.
The live and history reading positions survive a switch to Chat and back. Erased
transient output is not archived. Ghostty is not embedded in this client.

On Hosts advertising `remote-scroll`, **Scroll Up** and **Scroll Down** move the
Host pane by its current height minus three rows (at least one row). Native
scrollback moves exactly that far; application-managed scrolling uses an equivalent
precision wheel distance adjusted by Host internal Agent profiles (Codex: three
rows per event with eight rows reserved for composer/status). Host settings and
the application can still change the distance. The two buttons sit above the live
screen. Swipes only move the local reader, including at either edge, and long
presses keep native text selection. The bottom Follow latest controls remain
local reading controls. The remote scroll buttons operate the Host's current
terminal/application view; they are separate from History,
whose frozen snapshots and paging are unchanged.
Applications decide how terminal scroll input is handled, so the exact distance
can vary. Remote scrolling changes the view seen on Host as well.

One scroll waits for a fresh screen and matching Host acknowledgement; a spinner
ends after five seconds if no confirmation arrives. Timed-out or disconnected
scrolls are never replayed automatically. A fresh capture does not prove that the
application moved, including when it is already at the beginning or end. Following
latest text pauses during remote scrolling. After either scrolling up or down,
the local reader starts at the top of the returned screen. Hosts without
`remote-scroll` keep those two controls disabled.

Hosts advertising `scroll-state-v1` send explicit scroll boundaries with each
screen after the client opts in. The matching screen commits those boundaries:
Scroll Up is disabled at a known top, and Scroll Down at a known bottom. Unknown
boundaries, including application-managed TUI scrolling, leave both directions
available. Unchanged screen text is never treated as proof of a boundary. Older
Hosts with `remote-scroll` but no boundary capability still support both buttons.

One composer serves both views. **Send** first reads public Host `list`. Detected
Agents use `agentsInput` (`agent-input` capability), which delivers plain interactive
text without task dispatch receipts. Older Hosts must be updated. The Host does not
permit structured Shell submission because it cannot confirm that the Shell input line
is empty; the composer says so for a shell pane. Host validates the pane lease,
readiness, drafts and IME/editing activity. Input delivery is not Agent completion.
Messages also go to a working agent, which queues them or steers its turn as it does for
keyboard input on the Mac; only an agent that waits for an answer refuses them. A pending or unknown receipt shows
the submitted text with **Check Receipt** and **I've Checked**; the draft is preserved
and commands are never automatically replayed.

The composer is one line when unfocused, expands while editing, then scrolls at its
height limit. Send is explicit; Return inserts a newline. Two physical Returns
within 350 ms send when enabled, removing only the shortcut's first newline.
IME composition, editing/selection changes and lost focus cancel the gesture.
Pending or unknown delivery prevents another Send. A changed draft is never cleared
by an older receipt.

Disconnect, Host stop, pane closure, takeover and incompatibility retain the last
output with a red reason in the status pill. Retry/foreground recovery do not take
over another device; Take Over is explicit.

## Build and tests

Tuist generates the Xcode project from `Mirror/iOS/Project.swift`; the project file is not in
Git. Run `make generate` at the Prowl repository root, open `Prowl.xcworkspace`, and select the
`ProwlMirror-iOS` scheme. For work on this client only,
`mise exec -- tuist generate --path Mirror/iOS` generates `ProwlMirror-iOS.xcworkspace` in this
folder and does not need the Mac app's build inputs. Simulator signing stays enabled for Keychain tests. Unit tests cover wire vectors, native TLS transport,
command correlation/routing, reading and keyboard behavior. The Host's real App
target covers pairing, revocation, terminal capture and input protection; there is
no copied Host implementation in this client's tests.

Run the iOS mirror unit and UI suites on an iPad simulator:

```bash
make test-mirror-ios
```

The target generates only this project, so it does not need the Mac app's build inputs.
The UI suite takes several minutes. `make test-mirror-ios-unit` runs only the unit tests.
CI runs only the unit tests, and only when a pull request changes `Mirror/iOS/` or
`Mirror/Shared/`, and for each published release. Run the UI suite locally before you merge changes to
this client. The target uses the newest iPad Pro 11-inch simulator on the newest runtime that
the selected Xcode supports. To use another model, set `IOS_MIRROR_SIMULATOR_PATTERN` to a
regular expression for the full simulator name. The UI tests also pass on iPhone.

DEBUG-only launch arguments supply deterministic UI data without a Host or an Agent:
`--mirror-ui-fixture` opens a terminal pane (add `--mirror-ui-scroll-fixture`,
`--mirror-ui-multiple-fixtures` for long output, `--mirror-ui-large-table-fixture`);
`--mirror-ui-conversation-fixture [claude|codex]` opens a pane that replays the bundled
`Mirror/Fixtures/conversation/*.events.jsonl` as a chat; `--mirror-ui-connection-fixture`
shows the Hosts screen with one fake Host whose roster serves the same fixture pane;
`--mirror-ui-launch-fixture` opens the New Agent Pane form alone. Component and socket
tests are separate from real Agent/cross-device acceptance.

## TestFlight

`make testflight-mirror-ios` archives the Release build and uploads it to App Store Connect;
`make archive-mirror-ios` stops after it exports the IPA to `build/mirror-ios/export`. Both
need a clean working tree and the signing team in `Config/Local.xcconfig`
(`MIRROR_IOS_TEAM_ID` overrides it). Xcode automatic signing creates the distribution
certificate and profile. Authentication uses the `PROWL_ASC_*` API key in
`Config/Secrets.env` when it is set, and the Apple ID signed in to Xcode otherwise.

The version follows the Mac app's CalVer and is not committed: the marketing version is the
local date (`YYYY.M.D`) and the build number is the local time (`YYYYMMDDHHMM`), so every upload
has a larger build number. Set `MIRROR_IOS_VERSION` or `MIRROR_IOS_BUILD` to override them.
The script prints the commit of each build; add it to the TestFlight notes.

See the shared [wire contract](../../docs/remote-mirror-wire.md) and
`ThirdPartyNotices/` for source/license notices.

Ordinary Send requires Host capability `agent-input`. It does not add a completion
prompt or create a pending dispatch; prior automation receipts remain unchanged.
Delivery confirmation and reconnect receipt lookup remain separate from task success.

Use **Scan QR Code** in the Host connection form to scan **Add a Device** on Host.
Scanning connects with the encoded address, port and short-lived code. Camera
permission is optional; manual entry remains available. Refresh expired codes on Host.
