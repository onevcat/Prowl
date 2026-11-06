# Remote Mirror (experimental)

Two Prowl apps can view and control the same Host terminal. The Host keyboard stays
available. Each pane has one remote owner. Explicit **Take Over** replaces that
owner; **Retry** and foreground recovery only reconnect when the pane is free.
Ordinary **Mirror** on a pane listed as free does not take over a client that acquired
it after the list was read; use the explicit **Take Over** action.

## Enable and pair

Launch the Mac App with `PROWL_REMOTE_MIRROR=1`. The experiment is hidden and cannot
start a listener otherwise. Hover over the **Remote Mirror** network button to
preview, or click to keep it open. Under **Host**, pick **Listen on** and a port,
then **Start Host**. The picker offers all interfaces (`0.0.0.0`), each of this
Mac's IPv4 interfaces by name, and this Mac only (`127.0.0.1`); a value saved
from an earlier version appears as **Custom**. The icon is gray when stopped,
muted blue when listening, and muted green when at least one pane is mirrored.
A listener is reachable from the local network or a VPN; the internet cannot reach
it unless a router forwards the port. Without a paired device key or a live pairing
code, a connection fails during the TLS handshake.

**Add a Device** opens a modal pairing sheet with a 60-second code, a reachable
Wi-Fi or VPN address and port, and a QR code. **Copy Connection Details** (⌘C)
copies the address, port, code, and expiry together. When multiple addresses are
available, choose **Connection address** first. If the listener is restarting, the sheet waits before generating
its first code; if Host is off, the sheet offers **Start Host**. **Refresh Code**
replaces the code; **Cancel** invalidates an unused code without stopping Host or
revoking a device that already paired. When a device completes pairing, the sheet
shows **Paired with** its name and closes by itself. On the other Mac, open
**Remote Mirror → Client → Connect to a New Host** and enter the address (an IP or a
host name such as `mini.local`), port, and code. On iOS, **Pair with a Mac** on the
first launch, or **Add Host…** in the Mac menu, takes the same address, port and code, or
scans the QR code.
Successful enrollment consumes the code. The client saves its device credential in
Keychain, then opens a new authenticated connection. A pairing-only connection
cannot list or operate panes. No extra long-lived code is required. A saved
enrollment remains available for Retry if the first runtime connection fails.

On Mac, paired Hosts are listed under **Client** with their name and last
connection time. This list holds addresses only, stored outside Keychain, so hover
previews show it without reading credentials. Records written by an earlier
version are imported from Keychain once, after the first click on the Remote
Mirror button; if that import fails, a hint keeps **Connect to a New Host**
available and **Try Again** repeats it. Click **Connect** beside a Host to
authenticate and open the pane picker without entering the address or code again.
The **…** menu offers **Rename…**, a name shown on this Mac only, and **Forget**,
which removes the saved access. Saved entries do not imply that the Host is
online; connection failures appear in the connection sheet. In the connection
form the code field appears only when this Mac has no saved access for the
address. If the Host no longer recognizes this Mac, for example after **Revoke**,
the attempt fails at once with an explanation and the code field appears. A
refused port, an unreachable address, or an unresolved name also fails at once;
an unanswered connection gives up after ten seconds. Saved credentials survive
Host stop/start and App restart. They do not discover a changed IP address. On iOS,
a paired Host stays in the Hosts list with its credential and reconnects without a
code; **Rename** changes the name shown on the phone, **Forget** removes the entry and
its credential, and a Host that no longer recognizes the device needs a new pairing
through **Add Host**. A new Host or revoked device requires a fresh pairing window. Old
experiment keys are not migrated.

The Host section lists paired devices with **Connected** and the active mirror
count, **Last seen** for a device that is offline, or **Paired · never connected**,
plus mirrored pane names and **Revoke**, which asks for confirmation. Each active
mirror has a green dot and a red disconnect button. **Disconnect** asks for
confirmation, then disconnects only that mirror. The terminal keeps running,
other mirrors remain connected, and the device stays paired and can reconnect.
If that connection has already ended or been replaced, confirmation does nothing. A device
browsing panes can be connected with zero mirrors.
Device labels use the Mac local host name or the iOS system device name; pairing
does not resolve a DNS name to obtain this label.

Revocation removes the persisted secret and disconnects all connections for that device;
other devices remain connected. **Revoke All Devices…** asks for confirmation, then
removes every device's saved authorization, including offline devices, disconnects
all clients, and invalidates the current pairing code. Host keeps listening and
local terminals keep running. Saved client connections cannot reconnect until each
device pairs again with a fresh code. In the Mac connection form, **Pair Again…**
shows the code field and bypasses saved access even if the connection error was
reported as a network failure. Device records are limited to 64. If enrollment
succeeds on Host but its response or the client's save is lost, open a new window
and remove the unused device record. Unreadable saved entries are omitted from the Host list without deleting them.
Errors that prevent pairing or connection remain visible in plain language, naming
the address and the reason; a port already in use or an address this Mac does not
have stops Host with the same kind of message. Keychain
status codes are logged for diagnosis. Credentials are never stored as plaintext.

The pairing window changes the listener's TLS keys. Prowl waits for the old
listener's cancellation before rebinding its port; established connections survive.
Pairing success is sent only after the replacement listener can accept the new device credential.
Stopping Host closes remote connections but leaves Host programs running. Closing a
mirror only unsubscribes. Quitting Prowl does not promise that its programs survive.

## Panes, display and history

The Client sidebar lets you select a mirror by clicking anywhere in its row.
The native window toolbar places the pane title and subtitle after the Remote
Mirror button. The center shows connection status and the Host address; hover for
the full pane name, directory, and Host endpoint. On the right, the display-size
toggle switches between **Fit to Window** and **Original Size** with one click;
its icon shows the current mode. **History** opens retained text, and the red
disconnect icon closes that mirror without stopping the Host program.
**Retry** or **Take Over** stays visible when needed, and **Live Terminal** returns
from history to the live view.

Choose an existing pane or use **New Pane…** on Mac. Existing panes use their
terminal and worktree names without generated Tab N labels. The whole pane row
is clickable; **Refresh Panes** and **Cancel** share the bottom action row.
A project that has never opened a terminal is not yet a pane, but its worktree is
available in **New Pane…** on a current Host. The Host terminal owns the
grid. Mac clients default to **Fit to Window**, shrinking the complete terminal to
fit without changing the Host PTY. **Original Size** restores readable native-size
glyphs with local panning. It starts at the top; subsequent window resizes preserve
the manual scroll position within the available bounds. Large Host grids can make
Fit to Window text small. iOS
renders replacement text with local reflow. Cleared output is not an archive.

On iOS, the first launch asks you to pair with a Mac. After that the app opens on the
agents of the last Mac you chose, titled with the Mac's name; the Mac menu at the top left
switches the Host, adds one, or opens **Manage Hosts** (rename, forget). Three counts on
top show how many agents are **Blocked**, **Working** and **Done** (finished and not looked
at yet); tap one to show only those agents, tap it again to show all. The panes follow the
Mac sidebar: projects in sidebar order with their repository color and group, agents
sorted blocked, working, done, idle, each with its agent mark, tab title, worktree and how
long ago its state changed. Working shows the Bagua spinner, as on the Mac. Terminals
without an agent fold into one row per project. A pane opens in **Chat** when the
conversation is available and in **Terminal** otherwise. Its title shows the pane's name
and, under it, its state and project / worktree. The toolbar button next to **…** switches
Chat and Terminal on the same connection, and a Terminal pane whose agent starts moves to
Chat by itself unless you chose Terminal. A lost connection shows its reason with
**Reconnect** (or **Take Over** when another device mirrors the pane), and a blocked agent
shows what it waits for above the composer. The **…** menu holds **History** and **Live
Output** for the terminal, **Reconnect** or **Take Over**, and **Disconnect**. The list keeps refreshing behind the pane, so a new agent or a closed pane
is noticed within a few seconds.

On a Host advertising remote scrolling, **Scroll Up** and **Scroll Down** move
the live Host terminal by its current pane height minus three rows (at least one
row). Native scrollback moves by that exact number of rows. Application-owned
scrolling receives the equivalent precision wheel distance. Internal Agent defaults account for known application
wheel steps: Codex uses three rows per event and reserves eight pane rows for its
composer/status area, in addition to the three-row overlap. Unlisted Agents use
one row per event with no extra reservation. These are compiled constants, not
user settings, and never affect native Ghostty scrollback. Host precision-scroll
settings and application behavior can still affect TUI distance. These buttons sit above the live
view on all clients. Wheel and touch gestures only move the local readable view;
they never request remote scrolling. Each completed remote scroll resets the local
reader to the top in both directions, including Mac Original Size mode. On iOS the
two buttons are a small capsule at the top right of the reader, with **Scrolling…** or
an error to its left. The reader follows the newest output while its end is in view;
after you scroll away, an arrow button returns to it and following starts again.

A current Host sends frame-matched boundary state. **Scroll Up** is disabled at
a known top and **Scroll Down** at a known bottom. Native terminal scrollback can
provide these boundaries. Application-owned TUI history, or a screen whose range
cannot be established, leaves them unknown and the buttons available. An unchanged
frame does not prove a boundary. Older Hosts without boundary metadata keep both
directions available when remote scrolling is supported.

**Scrolling…** remains visible until a fresh Host frame confirms the request,
or a five-second timeout ends the wait. A boundary that does not change the frame
still completes. Requests are never automatically replayed after uncertainty.
The Host handles scrolling using its terminal's negotiated mouse/alternate-scroll
mode, aimed at the center of its grid. Application-specific scroll regions or
bindings can change the distance or response; this is not an exact line-number
navigation contract. Both devices share the Host view, so scrolling can move the
Host user's view too. An older Host leaves remote scrolling unavailable.

The Mac client keeps the original styled terminal while an application redraws
its own screen. Native terminal scrollback also keeps its styles when both Macs
support styled scrollback and the viewport can be reconstructed safely (see
**Native history appearance on Mac** below). Otherwise it displays
**Host scrollback · Plain text** using that viewport's physical rows. Returning
to the active viewport restores the styled terminal. This is selected from
terminal state, independent of the Agent being run; mobile remains text throughout.

History remains a separate, read-only view. Its scrolling and page loading do not
send remote scroll input or change the frozen snapshot. No output archive or
cross-frame text merging is added.

Host samples subscribed panes every 200 ms and allows only one unacknowledged frame
per subscription. Unchanged frames are omitted; text geometry and truncation are
also part of the change check. No subscriptions means no terminal sampling.

**History** pages one frozen retained-text snapshot, 200 lines at a time, with a
2 MiB UTF-8 budget. Refresh starts a new snapshot. Graphics, link targets and cursor
shape are not guaranteed by the formatter. Disconnected output remains visible,
with input disabled and a reason/retry action.

## Create from Mac

After connecting, **New Pane…** lists Host worktrees, including worktrees with no
open terminal. Choose **Shell** or **Agent Profile**; a Profile may include an
optional initial prompt. **Create and Mirror** creates one background tab through
the public CLI router and opens its mirror. The Host selection and focus stay put.
The display uses Host Profile availability; unavailable Profiles cannot launch.
An older Host that only advertises Profile creation does not offer Shell.

**Back** returns to existing panes. If creation cannot be confirmed, the form keeps
its values and blocks another creation; inspect the pane list before starting a
new connection to try again. No creation is replayed automatically after a timeout,
cancellation, or disconnect. Closing a mirror still leaves the Host program running.

## Create and send from iOS

**New Session** (the **+** on the Agents screen, or a project's **…** menu) is shaped like
the composer: the optional first message on top, and under it two menus. The project menu
lists the Host's repositories, with worktrees as a submenu, and starts on the project you
came from. The Profile menu shows each Agent Profile's agent, model and effort, and greys
out unavailable ones with the reason. The last Profile you started is chosen again. The
arrow starts the session and opens it. Host creates a normal background tab through its
public CLI router. There is no special AI Control Console, bundled private control
skill, or separate agent-launch implementation. Profile settings determine model
and permissions.

Every Send first reads public `list`. A detected Agent uses structured `agentsInput`
(`agents.input`), advertised by the `agent-input` capability. Update Host if this
capability is missing; mobile clients never fall back to task dispatch.
Interactive input delivers the message as written, without a `[Prowl]` prefix or a
completion instruction. It creates no dispatch record and does not require
`dispatch-complete`. An existing pending automation receipt is neither completed nor
abandoned and does not block this human input, just as local typing does not settle
an automation task. Like typing at the Mac, a message also goes in while the agent works:
the agent queues it or steers its current turn by its own rules (Claude Code queues it,
Codex adds it to the running turn). Only a blocked agent, one that waits for an answer to a
question or permission, refuses the message. The local input protections still apply.
Host rechecks the exact subscribed pane and lease, plus input protection, before delivery.
In a shell pane, the composer runs a command. The Host takes it only while the shell waits
for a new command at its primary prompt, which it learns from Ghostty's shell integration
(zsh, bash 4 and later, fish; not the macOS `/bin/bash` 3.2). It refuses when a program
such as `vim`, `less`, `ssh` or a script runs in front of the shell (and names it), at a
continuation prompt of an unfinished command, while a command such as a `read` waits for
input, and while someone types on the Mac. It clears the prompt line first (⌃E, ⌃U), so an
old draft on the Mac cannot join the command; ⌃Y on the Mac brings the draft back. A
one-line command is typed. A command with several lines or a tab is pasted, and only to a
shell that takes bracketed paste. Local CLI `send` and Mac mirror keyboard input keep their
direct-input behavior.

Shared Agent input delivery rejects IME composition and recent Host editing. Claude must
have a recognized empty composer; the dim `Try "…"` hint of a fresh session and the dim
queued messages hint of a running turn count as empty. It inserts text, waits up to two seconds for the paste echo, and only then sends
Enter, provided the surface/Agent/edit revision is unchanged. The echo may wrap anywhere,
also between two CJK characters; only spaces inside a row must match. Codex has an explicit
idle-composer rule. For both, the delivery boundary checks formatter dim styling so a
hint is not confused with an identically worded draft. When an earlier delivery left
its text in the composer without Enter, the same request gets Enter alone instead of a second
copy, but only for exactly that text and only while nobody has edited the composer since. A draft
that merely looks the same on screen (a collapsed paste marker, whitespace) is not trusted. Unknown layouts, other drafts and attachments refuse delivery,
and the refusal quotes the start of the draft.

A successful input receipt confirms delivery, not Agent completion. Replies are
correlated by UUID. Unknown delivery preserves the draft and is not automatically
replayed; reconnection queries the original request receipt on the same Host run.
If delivery stops after paste but before Enter, text may remain in the Host composer;
check it before retrying.

Host retains up to 1024 mutation receipts per App lifetime, and rejects further mutations
when full. Catalog reads do not consume this budget. A retained mutation ID reused with
different parameters is rejected. Takeover/disconnect cancels input still waiting for readiness. Explicit device revocation or Host stop
also cancels pending Profile preparation, including requests whose connection was
already lost. A plain disconnect alone does not cancel accepted Profile creation;
check Host before retrying an uncertain result. Existing terminal programs continue.

## Conversation view

A Host advertising `conversation-v1` can serve a pane as the agent's conversation instead
of its screen: the Host reads the agent's own transcript (Claude Code and Codex today),
its hooks and its OSC 7501 status, and sends normalized events (turns, messages, tool
cards with bounded output and diffs, prompts, status, session changes). The pane list
marks each pane `available`, `pending` (agent known, transcript not yet resolved) or
`unsupported`; Shell panes and other agents keep the text view. A client can switch a
pane between the conversation and the text view on the same connection, and resumes by
sequence after a reconnect while the Host still retains the feed (ten minutes). Assistant
text arrives when a message completes; `working` comes from the agent's status. Codex
without trusted hooks reports tools only when they finish and no approval content. See
[wire contract](remote-mirror-wire.md#conversation-stream-conversation-v1) and
docs-ai 087.

The iOS client renders the stream as a chat: your messages in bubbles on the right (long
ones fold after twelve lines), the agent's Markdown as text (headings, lists, quotes, code
blocks and tables), and each run of tool calls between two messages as one quiet row
("6 tool calls", with failures counted in red and the running call shown with a turning
hourglass while the agent works). A row opens to one line per call, and a line opens its command, changes and output
in a sheet. Thinking the agent shows as text in its pane (Claude Code's visible thinking,
Codex's reasoning summary) is its own row between the steps, in secondary type. While the agent waits on a choice (a permission, a question, Codex's approval), a panel
above the composer shows the question, what it is about (such as the command to approve) and
the choices; tap one to answer. In a multi-select question, each tap checks or unchecks a box
on the Mac and **Submit** sends the checked ones. A question in several parts ends on Claude's
"Ready to submit your answers?" page, which the panel offers too. The Host checks that the Mac
still shows the same question before it presses any key, so a stale tap is refused with a
reason, and typed answers stay on the Mac. Answered prompts leave one line in the chat. Instructions that Prowl adds to a launch prompt, such
as the dispatch completion protocol, fold under **Prowl instructions** in your message.
On a wide screen such as an iPad, the chat and its composer keep a readable column in the
middle. The chat opens at the newest message and stays there as messages arrive. The arrow button shows
only after you scroll away from the end and returns to the newest message. While you type, the
Hide Keyboard button floats above the composer. While the agent works and the
composer is empty, its button becomes **Stop**, which presses Escape on the Mac after you
confirm. In Terminal, agent and shell panes get a key bar (esc, ⌃C, ⇧⇥, ⇥, arrows, Return): menus in a
TUI, and in a shell ⌃C to stop a command, Tab to complete and the arrows for history.
When the Mac refuses a key or Stop, for example because someone is typing there, the reason
shows above the composer. The prompt panel shows in Terminal too, above the key bar. While a message is still on its way to the Mac, the key bar and prompt answers wait.
The iOS app logs connections, prompts and Host command results to the unified log under the
subsystem `com.onevcat.prowl.mirror-ios`; collect it with Console.app or `log collect --device`.
The floating composer
under both views sends through `agents.input`; a note appears only when the Host refused
something or a receipt needs a look. While the agent works, Send still delivers: the agent
gets the message as if it was typed on the Mac.

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

The Ghostty bridge from `onevcat/ghostty` PR #2, with keyboard-mode and styled-blank-cell
export fixes, is pinned at `5afdc9cf7315`.
The default build downloads the matching XCFramework and resources, verified against
`scripts/ghosttykit-checksums.txt`. No sibling Ghostty checkout is required.
Real Agent and cross-device acceptance remain separate from component/socket test evidence.

## Mobile client projects

Native clients live in [Mirror/iOS](../Mirror/iOS/) (iPhone and iPad)
and [Mirror/Android](../Mirror/Android/) (phones and tablets). Each
project retains its own build and test entry points; neither is built by the Mac
App target or release pipeline. See [client setup](../Mirror/README.md).

### Copy connection details to Mac

On Host, open **Add a Device**, choose the Wi-Fi or VPN address reachable from
Mirror, and click **Copy Connection Details**. This single copy includes the
address, port, pairing code and expiry. In Mac Mirror's connection form, paste
into the address, port or pairing-code field; all three fields fill together,
even when pasting into an existing value. Click **Connect** to pair. Fresh copied
details bypass saved device access, including credentials revoked by Host.
Expired or malformed details show an error without replacing existing fields.

### Scan to pair a phone

Open **Add a Device** on Host, then **Scan QR Code** in the mobile app's Host
connection form. The QR includes the numeric IP address, port and current pairing
code. Scanning starts the normal authenticated pairing flow and then offers the
Host panes. Choose the Wi-Fi or VPN address reachable from your phone in **Connection
address** when Host has multiple interfaces. Both devices still need network access
to that address; scanning does not create a tunnel.

The QR expires with the existing 60-second, single-use code. Refresh Code on Host
and scan again if it expires. Camera permission is requested only when scanning;
manual entry remains available if permission is denied or scanning is unsupported.
On Android, the scanner opens in portrait without a red scanning line. The Live
scroll toolbar places **Scroll up** and **Scroll down** at opposite ends, with
loading feedback between them. Each completed scroll moves the reader to the top
once. Switching panes or recreating the Android reader preserves subsequent local
reading positions instead of repeating that move.

### Native history appearance on Mac

When both Macs support styled scrollback, **Scroll Up/Down** keeps the same
terminal renderer, font, font size and colors used by the live Mirror display.
This is separate from **History**, which remains a retained-text snapshot.
Older Hosts, histories exceeding the replay limit, or a viewport that cannot be
reconstructed safely use the existing **Host scrollback · Plain text** fallback.
Mobile clients continue using text-v1 and require no update for this feature.
Mac frame updates also work with a fixed Ghostty `title`, including after a config
reload. If the local replica cannot confirm frame parsing within 30 seconds,
Mirror disconnects with an error rather than silently stopping updates. Reconnect
to try again.
