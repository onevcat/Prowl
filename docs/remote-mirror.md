# Remote Mirror (experimental)

Remote Mirror lets two Prowl apps interact with the same running Host terminal.
The Host keyboard stays available. Each pane has one remote owner; an explicit
**Take Over** replaces that owner, while automatic recovery never takes ownership
from another device. This branch is undergoing the review changes in PR #793.

## Enable the experiment

Launch Prowl with `PROWL_REMOTE_MIRROR=1` in its process environment. Without the
flag, Host and Add Remote Mirror controls and the mirror sidebar are hidden, and
the Host cannot start a listener. Ordinary terminal and CLI operation is unchanged.

## Host and Client

Open the network button, enter a listening address and port, and choose **Start
Host**. `0.0.0.0` listens on all IPv4 interfaces; use the Mac's reachable address
on the Client. The network icon turns green while listening. Copy the pairing
code, then use **Add to Prowl → Remote Mirror Pane** on the other Mac. Select an
already-created terminal; sidebar projects alone do not create terminal sessions.
**Refresh Panes** retrieves the current list.

The current transport still uses a short TLS ECDHE-PSK code for a Host run.
Persistent device enrollment and the new command protocol are being implemented;
this is not yet the reviewed pairing design. Do not rely on compatibility between
experimental builds. The former AI Control Console has been removed. iOS can choose **New Agent Pane**,
select a worktree and an available Host Profile, and optionally supply an initial
message. The Host creates an ordinary background tab through its existing CLI
command router. The Profile determines the model, permissions and launch settings.

Closing a mirror unsubscribes without stopping the Host program. Stopping Host
closes remote connections without closing local panes. Quitting Prowl stops the
service and does not promise that its programs survive. **Retry** reconnects to a
free pane and requests a fresh display; an occupied pane requires explicit takeover.
Disconnected displays remain visible with remote input disabled.

## Display and history

The Host owns the terminal grid. Smaller Client windows scroll the canvas rather
than resize the Host PTY. The Host samples subscribed panes every 200 ms, sends
only changed full VT frames, and waits for acknowledgement before sending another.
Without subscriptions, no frames are read. Keys and pasted bytes are forwarded to
the Host. Heartbeats run every two seconds; eight seconds without incoming traffic
ends an established connection.

**History** reads retained text in 200-line pages from one bounded snapshot, up to
2 MiB of UTF-8 text. **Load Earlier** stays within that snapshot; **Refresh** replaces
it. Erased transient output is not archived. The Ghostty formatter is not a complete
terminal checkpoint: graphics, link targets and cursor shape are not guaranteed.

Mac display replicas use the dedicated `prowl-mirror-relay` executable bundled under
`Resources/prowl-mirror-relay/`. It has no external dependencies and connects only to the Client's
loopback listener. It never starts a remote program or another Prowl App instance.
Its local framing is independent of the remote protocol: kind:u8, length:u32
big-endian, then payload. Authentication carries a per-replica random token;
frames carry sequence:u64 followed by raw VT bytes; acknowledgements carry that
sequence; input carries raw keyboard bytes. Payloads are bounded to 8 MiB. Socket
or stdin EOF exits the helper.

## Mobile transition

Plain-text mirroring and bounded retained history remain available. The old
mirror-private submission parser and ledger have been removed. Updated iOS clients
use the public Agent dispatch route below. Do not use an old iOS build to validate
this path. Shared terminal delivery protection and Shell Send are still unfinished;
this intermediate branch is not a release candidate.

## Development

`make embed-cli-debug` builds and embeds both executables. Release embedding builds
both architectures, and Xcode signs the relay during its copy phase before signing the App.
`scripts/test-remote-mirror.sh` runs the real App test target; relay codec tests run
with `swift test --filter MirrorRelayPacketTests`.

The required Ghostty bridge was merged in `onevcat/ghostty` PR #2. Until a matching
artifact is published and pinned, use a locally built sibling Ghostty via
`PROWL_GHOSTTY_SOURCE_DIR=../ghostty make build-app`. The old pinned artifact does
not export the required APIs. This temporary dependency gap must be resolved
before treating a fresh checkout as a self-contained build.

## Structured iOS launch

Hosts advertise `launch-profile` when the command router is attached. The current
experimental discovery command bridge exposes only `list`, `profiles`, and Profile-backed
`create tab` in an existing worktree. It cannot execute a client-supplied shell
command or change Profile permissions. Commands are allowed only on authenticated
discovery connections, before subscribing to a pane.

Each command has a UUID request ID and an inline CLI JSON envelope; the response
carries that ID and the original CLI result shape. Duplicate IDs return the original
operation's result, including across connections. Reusing an ID with different
parameters is rejected. The App retains up to 1024 request receipts for its lifetime;
when full it refuses new commands rather than evicting a creation receipt and risking
reexecution. Clients never automatically replay a command after timeout or disconnect.
If creation is unconfirmed, refresh the pane list before making another request.

This is an incremental bridge on the current experimental transport. The typed
network protocol, persistent device enrollment, and shared terminal delivery
refinements remain separate unfinished review items.


### Agent dispatch from iOS

The Host advertises `agents-dispatch` when the public command router is attached.
A subscribed iOS client sends `agentsDispatch` with its current lease and exact pane
UUID. Host checks both against its subscription table before calling the public
`agents dispatch` handler. Discovery connections cannot dispatch; a client cannot
target a different pane. Takeover, disconnect and Host stop cancel a dispatch that
is still waiting for idle evidence. The public handler owns the readiness decision.

The reply confirms dispatch, not Agent completion. Busy/blocked/missing-Agent
refusals preserve the draft. Unknown delivery blocks another send until the user
checks Host output; reconnect queries the original command receipt without
replaying text. Receipts are bounded and App-lifetime only, and require a current
lease for the same pane. This receipt lookup does not complete or abandon Agent
work. Shell send, shared local-draft/IME protection and Claude paste/Enter evidence
remain separate review-alignment work; the route tests do not establish those
terminal behaviors. The previous `submit-text` protocol remains only in the iOS
legacy fixture path until the final wire cleanup.


### Shared input protection checkpoint

Public Agent dispatch checks Host IME composition and editing activity before and
after its idle wait. Marked text always refuses delivery; editing within two seconds
also refuses it. Claude additionally requires a recognized empty composer, using
its shared screen profile: multiline drafts and image/paste markers refuse dispatch.
A missing composer is not considered empty. These checks apply to CLI dispatch as
well as mirror dispatch and run before text insertion can clear marked text.

This does not yet verify Codex placeholder-versus-draft styling, nor implement the
Claude paste acknowledgement/Enter sequence or Shell Send. The screen check is
based on rendered text and is not a terminal-native draft API. Real terminal
acceptance remains required; component tests do not establish those pending paths.
