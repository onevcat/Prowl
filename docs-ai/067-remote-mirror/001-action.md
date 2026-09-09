# 067 — Remote Mirror: Initial Implementation

## Timeline
| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-09 | Added native Host settings, remote pane connection flow, service lifecycle, and display relay | Local branch `feat/remote-mirror` |
| 2026-09-09 | Added bounded VT protocol, exclusive subscriptions, retained-text paging, and TLS pairing | `supacode/Features/RemoteMirror/` |
| 2026-09-09 | Validated protocol/Host tests independently from App dependencies | `scripts/test-remote-mirror.sh` |

## Outcome and current state
The acceptance build at `581e97a7` built against the local Ghostty bridge. App-hosted
protocol and workspace regression tests pass. Real Host/Client Ghostty surfaces now
pass App-hosted integration tests; native UI and pixel presentation remain unverified.
Subsequent user-led two-Mac testing exercised the UI and prompted viewport and naming fixes.
The Draft now excludes unrelated workspace/compiler and icon changes; earlier build
results are not evidence of a clean build of this narrowed tree.
See [003-ui-and-draft-scope.md](003-ui-and-draft-scope.md). The feature is not release-ready.

- Host toolbar control next to notifications, with IP/port settings and start/stop.
- Add to Prowl includes Remote Mirror Pane, a connection form, and Host pane selection.
- Remote Mirrors sidebar group and a dedicated terminal detail view.
- MainActor service owns connections and stops with App termination.
- A pane has one remote subscriber; discovery does not sample terminal output.
- 200 ms changed-frame polling, one outstanding frame, TLS 1.2 random PSK pairing.
- Private app subprocess supplies the Client PTY's VT output and returns encoded input.
- Host dimensions are authoritative; Client displays a scrollable fixed grid.
- Retained text is bounded to 2 MiB and paged in 200-line batches using a snapshot ID.
- Local Ghostty framework override uses the sibling bridge build; no upstream artifact is relabeled.

## Verification
- Eight focused Swift Testing tests passed, including UTF-8 history boundaries and real TLS listener/connection
  tests for lazy capture, `PANE_BUSY`, raw input delivery, stop lifecycle, and wrong-key
  metadata denial. The Host test uses an injected terminal source, not an actual Ghostty surface.
- Production relay exercised under a real PTY: fragmented inbound frames, exact VT
  bytes, raw arrow/Ctrl-C/paste bytes, heartbeat response, and exit on disconnect passed.
- New adapter types passed Swift type checking with real Ghostty C headers and minimal
  surrounding App stubs. Modified Swift files passed syntax parsing. These checks do
  not replace compilation against the complete App.
- `make check` passes, including strict SwiftLint and 152 script tests.
- CLI and complete Debug App compile successfully with Xcode 26.3 / Swift 6.2.4.
  The `make build-app` log formatter (`xcsift`) was killed by SIGKILL; running the
  underlying Xcode build directly with a raw log succeeded without changing signing.
- App-hosted `MirrorProtocolTests`, `MirrorHostTests`, and `ProjectWorkspaceTests`
  pass: 35 tests, 36 parameterized cases, zero failures. The rollback regression
  covers both normal failure and cancellation; Git cleanup remains detached while
  synchronous file deletion no longer captures a non-Sendable FileManager across tasks.
- Host history dispatch and Ghostty initialization were extracted to satisfy lint.
  Byte-bounded history now drops an incomplete leading UTF-8 scalar instead of
  introducing a replacement character. Image sizing uses equivalent `scaledToFit()`.
- The initial verification did not cover real terminal surfaces. The follow-up now
  covers terminal state and history through the production network/relay path;
  subsequent user-led two-App/LAN use is recorded in the follow-up. Physical IME
  parity and a systematic pixel/toolbar layout audit remain unverified.

## Deviations and remaining work
- Native TLS/TCP replaces the originally proposed WebSocket transport; no browser client.
- History is a separate retained-text view, not styled Ghostty scrollback replay.
- Reconnect currently means closing and re-adding the mirror; no automatic retry.
- Mirrors occupy the detail area individually; mixed local/remote split trees are not implemented.
- The pinned Ghostty backend requires a PTY; the internal app relay follows the upstream
  spike instead of modifying Ghostty's IO backend.
- Verify native UI; real terminal integration tests do not establish pixel or
  physical keyboard/IME parity.
- Check grid presentation, key focus/IME, and live/history switching in the actual App.
- Before publishing, pin Prowl's Ghostty submodule to a reachable bridge commit; the
  current local branch deliberately uses `PROWL_GHOSTTY_SOURCE_DIR` instead.
