# Remote Mirror (experimental)

Two Prowl apps can view and control the same Host terminal. The Host keyboard stays
available. Each pane has one remote owner. Explicit **Take Over** replaces that
owner; **Retry** and foreground recovery only reconnect when the pane is free.

## Enable and pair

Launch the Mac App with `PROWL_REMOTE_MIRROR=1`. The experiment is hidden and cannot
start a listener otherwise. Open the network button, choose a listening address
and port, and **Start Host**. `0.0.0.0` listens on all IPv4 interfaces; clients enter
the Mac's reachable address instead.

**Add a Device** opens a 60-second pairing window. Copy or type the eight-character
code into **Add to Prowl → Remote Mirror Pane** on Mac or iOS. Successful enrollment
consumes the code. The client saves its device credential in Keychain, then opens a
new authenticated connection. A pairing-only connection cannot list or operate
panes. No extra long-lived code is required.

For a previously paired address, leave the code blank. Saved credentials survive
Host stop/start and App restart. They do not discover a changed IP address. The iOS
connection editor can retain a device credential while updating the Host address;
the client checks the Host identity after connecting. A new Host or revoked device
requires a fresh pairing window. Old experiment keys are not migrated.

The Host panel lists paired devices, their online state, and **Revoke**. Revocation
removes the persisted secret and disconnects all connections for that device;
other devices remain connected. Device records are limited to 64. If enrollment
succeeds on Host but its response or the client's save is lost, open a new window
and remove the unused device record. Keychain failures are reported, not replaced
with plaintext storage.

The pairing window changes the listener's TLS keys. Prowl waits for the old
listener's cancellation before rebinding its port; established connections survive.
Stopping Host closes remote connections but leaves Host programs running. Closing a
mirror only unsubscribes. Quitting Prowl does not promise that its programs survive.

## Panes, display and history

Select an already-created pane; a sidebar project that has never opened a terminal
is not yet a pane. **Refresh Panes** refreshes this list. The Host terminal owns the
grid. Mac clients scroll a smaller viewport rather than resize the Host PTY. iOS
renders replacement text with local reflow. Cleared output is not an archive.

Host samples subscribed panes every 200 ms and allows only one unacknowledged frame
per subscription. Unchanged frames are omitted; text geometry and truncation are
also part of the change check. No subscriptions means no terminal sampling.

**History** pages one frozen retained-text snapshot, 200 lines at a time, with a
2 MiB UTF-8 budget. Refresh starts a new snapshot. Graphics, link targets and cursor
shape are not guaranteed by the formatter. Disconnected output remains visible,
with input disabled and a reason/retry action.

## Create and send from iOS

**New Agent Pane** selects an existing Host worktree and an available Agent Profile,
with an optional initial prompt. Host creates a normal background tab through its
public CLI router. There is no special AI Control Console, bundled private control
skill, or separate agent-launch implementation. Profile settings determine model
and permissions.

Every Send first reads public `list`. A detected Agent uses public `agents dispatch`;
an explicitly idle Shell uses public `send`. Host rechecks the exact subscribed
pane and lease, plus input protection, before delivery. Unknown/running Shell state
refuses Send. Task state is currently worktree-scoped, so a different running task
in the same worktree can conservatively prevent Shell Send.

Shared Agent dispatch rejects IME composition and recent Host editing. Claude must
have a recognized empty composer. It inserts text, waits up to two seconds for the
paste echo, and only then sends Enter, provided the surface/Agent/edit revision is
unchanged. Codex has an explicit idle-composer rule; the delivery boundary also
checks formatter dim styling so a hint is not confused with an identically worded
draft. Unknown layouts, wrapped drafts and attachments refuse delivery.

A successful dispatch receipt confirms delivery, not Agent completion. Replies are
correlated by UUID. Unknown delivery preserves the draft and is not automatically
replayed; reconnection queries the original request receipt on the same Host run.
Host retains up to 1024 requests per App lifetime, and rejects further requests
when full. A reused ID with different parameters is rejected. Takeover/disconnect
cancels a dispatch still waiting for readiness. Existing terminal programs continue.

## Protocol and development

See [wire contract](remote-mirror-wire.md). This replaces the earlier experimental
protocol: upgrade both ends together. There is no version negotiation, legacy
64-character key, private `submit/state` protocol, or copied mobile Host fixture.
Mac Host behavior is tested in the real App target; iOS tests its client plus a
native TLS transport and the same fixed wire vectors.

Mac replicas use the separately bundled `prowl-mirror-relay`. Its loopback protocol
is distinct: kind:u8, length:u32 big-endian, payload. A private per-replica token
protects input forwarding. The helper exits on socket/stdin EOF and never launches
a remote program. `make embed-cli-debug` builds/embeds both CLI and helper;
`scripts/test-remote-mirror.sh` runs the App-target mirror tests.

The Ghostty bridge is merged in `onevcat/ghostty` PR #2. A matching official
XCFramework still needs publishing/pinning. Local tests use the sibling framework;
this does not establish a self-contained fresh-checkout build. Real Agent and
cross-device acceptance remain separate from component/socket test evidence.
