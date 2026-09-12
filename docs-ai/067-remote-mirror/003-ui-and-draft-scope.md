# 067.003 — UI interaction contract and Draft scope

## Context

The user exercised separate Prowl apps on two Macs and reported useful live agent
mirroring. Follow-up changes addressed clipped picker rows, Client scrolling,
Host status visibility, disconnect feedback, and ambiguous pane names. This is
user-led smoke evidence, not a systematic compatibility or visual acceptance suite.

## Host interaction

| State / action | Behavior |
| --- | --- |
| Network toolbar button | Opens a settings popover with listen IP and port. |
| Start Host | Creates an App-owned TLS listener and a fresh random pairing key. |
| Listening | Network icon becomes green; settings show subscriber count and pairing key. |
| Close popover | Listener remains running. No terminal is sampled without a subscription. |
| Stop Host | Disconnects remote clients and releases subscriptions; local programs continue. |
| Quit App | Stops the listener. Terminal survival is not guaranteed. |
| Address in use | Start fails; stop the other listener or select another port. |

`0.0.0.0` is a bind address, not the destination a Client should enter. The Client
uses a reachable address of the Host Mac. Only terminals owned by that App instance
are eligible. A sidebar project that has never opened a terminal is not a live pane.

## Client interaction

1. Add to Prowl → Remote Mirror Pane opens the connection form.
2. Enter Host IP, port, and pairing key. Connection authenticates before listing panes.
3. The picker shows repository folder name, Tab title, worktree name, and positions
   when multiple tabs/splits exist. Custom Tab titles are preserved. Empty/default
   titles fall back to agent identity or Shell. The path is available on hover.
4. Selecting a row subscribes to its UUID and adds a Remote Mirrors sidebar entry.
   Display labels do not identify the protocol target. Occupied rows show In use;
   Host also enforces exclusivity if two clients race to select the same pane.
5. Refresh Panes fetches current names and availability. Renames are not live-pushed
   to an already selected mirror. Older Host descriptors retain a legacy fallback.

The Host grid is authoritative. Client uses a fixed-size Ghostty canvas inside one
AppKit scroll view; wheel events move the Client viewport, never resize or scroll
the Host. The initial viewport includes the bottom input area. Resizing while at
the bottom keeps that edge visible; an explicit scroll away is preserved.

Local and remote keyboard input remain enabled simultaneously. This is one remote
subscriber plus the local user, not a control-token or multi-viewer system.

History is a separate text view: 200-line pages from a bounded 2 MiB snapshot.
Load Earlier retains snapshot identity; Refresh obtains a new snapshot. Live output
does not alter the viewed history. Erased transient content is not archived.

## Connection lifecycle

The header shows Connected/Disconnected. After loss, the sidebar marks Disconnected,
the terminal is replaced by explanatory text, and replica input stops. Transport
closure is handled when reported by Network.framework. Silent peers expire after
8 seconds without an incoming message; 2-second ping/pong traffic keeps idle terminals
alive. Initial setup retains a 30-second deadline. These deadlines depend on process
scheduling and are not a guarantee during sleep or a stalled App.

Close Mirror releases only its subscription. Reconnect currently means closing and
adding a mirror again. Client cannot infer remote process survival from connection
loss. Closing a remote-desktop viewer alone does not stop Host.

## Dependency and review boundary

- Ghostty prerequisite: `Awhisper/ghostty`, `feat/mirror-bridge`, commit
  `02b3c67044c5b2a0f99c8184e17bf47ab5396d3d`, adapted from onevcat/Prowl #788.
  That branch is published; no Ghostty PR has been created by this work yet.
- The required symbol is `ghostty_surface_read_snapshot`. The existing Prowl
  submodule/artifact pin does not include it. Default fresh-checkout builds are
  not ready; keep this change Draft until the dependency pin/artifacts are resolved.
- `PROWL_GHOSTTY_SOURCE_DIR` remains an opt-in developer path. No XCFramework,
  binaries, dependency caches, SSH details, or pairing keys belong in the PR.
- The unrelated `ProjectWorkspace` concurrency fix and regression changes, and
  `RepositoryIconImage` formatting changes, were removed from the final diff.
  They remain available in commit history for separate discussion. Reintroducing
  the base workspace code may reproduce the earlier Swift 6.2 compiler diagnostic.
- No CI behavior is weakened or disabled. A Draft does not waive the need for a
  reproducible build before merge. Full CI and integration against the final
  Ghostty dependency remain merge gates, not claims of this submission.

## Evidence and open work

At `581e97a7`, the complete Debug build, strict checks with 152 script tests, and
10 focused App-hosted tests passed. Earlier suites additionally covered control
bytes, dimensions, exclusive subscriptions, lifecycle, and silent-peer timeout.
Those results describe the acceptance builds before scope cleanup, not the final
Draft tree. The user reported successful two-Mac use; not every later UI change
has an explicit individual acceptance report.

Remaining: systematic native UI/IME/font/scale review, full CI, final dependency
integration, and author review of protocol/API boundaries. Automated GUI preflight
was unavailable because agent-ctrl was absent; no GUI pass is claimed.

After scope cleanup, `git diff --check` passed. Strict SwiftLint reports five
`legacy_swiftui_aspect_ratio` errors in the restored, unchanged
`RepositoryIconImage.swift`. The Draft deliberately does not fix or suppress these
base-tree violations. Earlier green check results do not apply to this tree.
The raw Debug Xcode build also fails at `ProjectWorkspace.swift:608` with the
restored sending-closure/data-race diagnostic under Swift 6.2.4, even when the local
Ghostty bridge is present. This base-tree issue is separate from the missing default
Ghostty dependency and needs separate resolution before merge.
