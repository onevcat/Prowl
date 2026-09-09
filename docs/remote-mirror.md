# Remote Mirror panes

Remote Mirror connects two Prowl apps to the same running Host terminal. Both the
Host keyboard and one remote keyboard can send input. Each Host pane permits one
remote mirror. With protocol v2, explicitly selecting **Take Over** replaces the
previous remote owner; automatic recovery never takes ownership from another device.

## Host

Open the network button next to notifications. Enter the listening IP and port,
then choose **Start Host**. `0.0.0.0` listens on all IPv4 interfaces; a specific local
IP restricts the listener to that address. Use this Mac's reachable IP on the Client.
Copy the random pairing key from the panel. Closing the panel keeps the service on.
**Copy Pairing Key** writes directly to the clipboard without opening system sharing.
Optionally enable **AI Control Console** before starting Host. Choose an Agent Profile,
model, approval mode and working directory. An empty directory uses Application Support.
The console is a named terminal with an independent **Open AI Control Console** entry;
its launch failure does not stop sharing. Configuration changes require restarting
the console. See [the control-console guide](remote-mirror-control.md).
The network icon turns green while Host is listening.
Stopping Host disconnects mirrors without closing any local pane or program.
Quitting Prowl stops the service. This is not a detached terminal daemon.

## Client

Open **Add to Prowl → Remote Mirror Pane**. Enter the Host IP, port, and pairing key.
Connect, then select an available pane. The mirror appears under **Remote Mirrors**
in the sidebar. Closing it only disconnects the remote subscription.
Only already-created terminals in the App instance running Host are listed; project
entries alone do not start a pane. After opening more terminals on Host, choose
**Refresh Panes**. **Take Over** means another mirror occupies that pane. Older Hosts
still show a disabled **In use** row because they do not support takeover.
The last successfully authenticated address, port and key are saved in Keychain and
prefilled next time. Prefilling does not connect or select a pane automatically.
The picker shows the repository folder name above the Tab title and worktree name.
Unnamed terminals fall back to the detected agent or Shell. Multiple tabs and split
panes include their positions so identical titles remain distinguishable. The sidebar
and header use the same project/terminal identity; hover for the full path. These
labels are captured when the pane list is refreshed.
After a disconnect, **Retry** requests a fresh baseline in the same mirror. If another
device owns the pane, use **Take Over** explicitly. The last display remains available
but remote input is disabled. Known takeover, Host stop and pane closure are shown
separately; unexplained connection loss means remote status is unknown.
An established connection sends a heartbeat
every 2 seconds and times out after 8 seconds without an incoming message; a silent
terminal remains connected because heartbeat replies do not depend on output.
Initial connection setup has a 30-second deadline. After a connection loss, the
Client cannot determine whether the Host's program is still running.

The Host owns the terminal grid dimensions. A smaller Client scrolls the replica
canvas instead of resizing the Host PTY. Colors, cursor location, and changing
terminal text are transferred as complete VT frames. Scroll over the live terminal
to move its canvas vertically or horizontally when it exceeds the Client window.
The viewport starts at the bottom so the input area remains accessible; use History
for retained content outside the Host's current screen. The Host samples subscribed
panes every 200 ms, and only sends changed frames. A slow link holds at most one
unacknowledged frame per pane. With no subscriptions, the Host does not read frames.
Each frame replaces the replica's display and terminal modes; remote key and paste
bytes are forwarded to the Host without re-encoding the text.

**History** loads retained text, 200 lines per request, from a bounded snapshot of
the Host's terminal history and screen (up to 2 MiB of UTF-8 text, trimmed at a complete character boundary). **Load Earlier**
fetches preceding pages of that same snapshot. **Refresh** requests current retained
text. Live output does not scroll this view. History currently preserves text, not
cell styling. Erased transient output is not recorded or recoverable.
The Client validates page continuity, snapshot identity and the cumulative UTF-8
budget. A repeated or inconsistent page ends the connection instead of appending
duplicate or unrelated history. Reaching the first retained line stops pagination.

## Native mobile client under development

Version-two discovery advertises plain-text mirrors separately from the Mac VT
representation. The iPad client reflows full ACTIVE-text replacements and retains
drafts across disconnection. Code fences and pipe tables can open a frozen detail
view. Markdown already rendered away by an Agent cannot be reconstructed reliably.
The working branch includes bounded retained-history capture and an initial Codex
submission adapter. The Mac integration builds with the local bridge and has real
terminal capture tests; live Agent submission verification is still incomplete.
Existing installed builds do not gain these capabilities.

Mobile Send requires an identified, idle Codex or Claude Code process, an editable empty composer,
bracketed paste support, and two seconds without changes
to the observed screen or local editing activity. Input is checked again immediately
before enqueueing the multiline paste and Return. A delivery receipt confirms the
terminal enqueue, not that the Agent has completed or even begun the requested work.
Attached-image evidence, startup, approval prompts and unsupported Agent composers
keep Send unavailable. Codex requires its styled placeholder; Claude Code requires
an empty single-line composer between its borders and its software-cursor marker.
Unrecognized composer layouts and other Agents keep Send unavailable.

On a Host advertising `refresh`, returning to the foreground requests a fresh text
frame on the existing subscription. It does not disconnect or compete for its own
pane again. Refresh preserves the one-outstanding-frame limit. After an actual
disconnect, Retry still connects only if the pane is free.

The iPad connection editor can update the address, port and pairing key. A new
address or port opens pane selection; a key update for the same endpoint retries
the selected pane without taking it from another device. Only verified connection
details replace the saved Keychain entry.

AI control-console settings remember the enabled option, Profile, model, bypass
option and working directory. Restoring settings alone does not launch an Agent;
startup remains tied to starting Host. A removed Profile requires a new choice.

## Transport and current boundaries

The native connection uses TLS 1.2 with a randomly generated pre-shared pairing
key. The key changes whenever Host starts. It authenticates before terminal
metadata or content is sent. There is no public web endpoint or new `prowl` command.
An internal subprocess of the app executable connects only to the Client's loopback
listener and renders VT data into the replica PTY. It never runs the Host's program.

The Ghostty bridge exports display state, not a complete terminal checkpoint.
OSC 8 link targets, cursor shape, and terminal graphics are not guaranteed. Brief
updates between samples may be skipped. Native app integration is under development;
see the implementation record for verification status before relying on this build.

## Local development

The opt-in `MirrorTerminalIntegrationTests/liveCodexComposerRejectsHostDraft()`
contract launches an installed Codex in a disposable directory with process-local
configuration. Set `TEST_RUNNER_PROWL_RUN_LIVE_MIRROR_CODEX=1` and
`TEST_RUNNER_PROWL_MIRROR_CODEX_EXECUTABLE` to its executable when running
`xcodebuild test`. By default it only checks readiness and local draft protection.
Adding `TEST_RUNNER_PROWL_MIRROR_CODEX_SEND=1` permits one short inference request
to verify native terminal delivery and rejection of a stale second submission.

`liveClaudeComposerCapture()` checks the real Claude Code composer, rejects a local
draft and stale duplicate, and verifies one multiline submission through an installed
runtime. Enable it with `TEST_RUNNER_PROWL_RUN_LIVE_MIRROR_CLAUDE=1` and supply a JSON
argv array in `TEST_RUNNER_PROWL_MIRROR_CLAUDE_ARGV`. No personal launcher is required
by the product; a provider-specific launch command belongs in local test configuration.

`liveControlConsoleReadsItsBundledGuideAndCLI()` exercises the actual control-console
launch and its private CLI endpoint. Enable `TEST_RUNNER_PROWL_RUN_LIVE_CONTROL_CONSOLE=1`
and provide an existing, trusted test workspace in `TEST_RUNNER_PROWL_TEST_CONSOLE_DIRECTORY`.
It uses the installed Codex executable above and an unrestricted test Profile to read
the packaged instructions and inspect this isolated instance. Prepare directory and
hook trust before running; hook approval inside the test additionally requires the
explicit `TEST_RUNNER_PROWL_TEST_TRUST_CODEX_HOOKS=1` opt-in.

Live tests can forward process-local proxy values through `TEST_RUNNER_PROWL_TEST_`
followed by `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, or `https_proxy`. Keep machine
addresses and provider configuration in ignored local files, not committed fixtures.

This branch requires the mirror bridge build of Ghostty. Build the sibling Ghostty
repository first, then use:

```sh
PROWL_GHOSTTY_SOURCE_DIR=../ghostty make build-app
```

The base display bridge is available in `Awhisper/ghostty` on `feat/mirror-bridge`, commit
`02b3c67044c5b2a0f99c8184e17bf47ab5396d3d`. Mobile history additionally requires the
local bounded-text bridge on `feat/mobile-mirror-bridge`, commit `df5b32481`.
The override copies its built XCFramework
and terminal resources without changing the pinned upstream artifact. The default
submodule/artifact does not yet export the required API: this branch is a Draft
integration, not a self-contained fresh-checkout build. The Ghostty dependency must
be integrated before merge.
