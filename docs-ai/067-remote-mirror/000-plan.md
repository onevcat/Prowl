# 067 — Remote Mirror: Plan

| | |
| --- | --- |
| **Status** | Debug build and focused tests pass; end-to-end UI verification pending |
| **Anchor date** | 2026-09-09 |
| **Related** | [061](../061-native-toolbar-controls/000-plan.md), upstream #788 |

## Background
A second Prowl app should view and interact with an existing terminal, including
transient TUI updates that agent events cannot represent. The original app must
remain usable locally and own the running process throughout the connection.

## Goals
- An app-owned, opt-in Host listener, configured from a toolbar popover.
- Remote Mirror Pane creation from Add to Prowl, with connection and pane selection.
- One remote subscriber per Host pane; local input remains enabled.
- Read active-screen VT snapshots only while subscribed, at 200 ms intervals.
  Send only changed frames, with bounded buffering and full replacement semantics.
- Disconnecting a client or stopping the listener never closes a Host terminal.
- Retained history is browsable independently from live output; erased transient
  output is not an archive. History requests must not scroll the Host viewport.
- Local development uses the sibling Ghostty bridge build without remote pushes.

## Design / Approach
Keep connection lifecycle and mirror state in a MainActor Observable service next
to the existing WorktreeTerminalManager. Native views use the service through the
SwiftUI environment. Local pane discovery uses existing active worktree states.
The existing Ghostty surface and its input encoding are reused on the Client.
An internal display relay owns only the replica PTY; it never starts an agent.
The relay is a private mode of the app executable, not a user-facing CLI/service.

The transport uses Network.framework TLS with a random pairing key. Connections
are authenticated before pane metadata, terminal content, or input are exchanged.
Length-prefixed messages have explicit size limits. A subscriber must acknowledge
frames before another frame is sent; slow receivers cannot accumulate snapshots.
Host dimensions are authoritative. Reconnecting creates a new baseline.

History starts with a bounded retained-text snapshot, paged under a connection-local
snapshot identifier. This preserves independent scrolling without pretending that
mutable row offsets remain valid across reflow or eviction. History text does not
claim to preserve terminal graphics or original cell styles.

## Alternatives & decisions
Agent-event-only rendering misses transient TUI updates. Replaying raw PTY output
requires capture before attachment and changes the Host IO path. Active-screen VT
exports reuse upstream's demonstrated bridge while keeping core Ghostty unchanged.
The pinned Ghostty backend only supports exec/PTY. An internal relay follows the
upstream spike without introducing a new Ghostty IO backend in this feature.
TLS over TCP is sufficient for native App-to-App transport; WebSocket adds no
capability needed here. Browser clients are outside this implementation.

## Amendments

- Updated 2026-09-09: Initial adapter and focused tests added; full App build blocked by dependency downloads — see [001-action.md](001-action.md).

- Updated 2026-09-09: Dependencies, Debug compilation, lint, and App-hosted regression tests now pass; real mirror UI verification remains pending — see [001-action.md](001-action.md).
