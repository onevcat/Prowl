# 067 — Remote Mirror: Initial Implementation

## Timeline
| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-09 | Added native Host settings, remote pane connection flow, service lifecycle, and display relay | Local branch `feat/remote-mirror` |
| 2026-09-09 | Added bounded VT protocol, exclusive subscriptions, retained-text paging, and TLS pairing | `supacode/Features/RemoteMirror/` |
| 2026-09-09 | Validated protocol/Host tests independently from App dependencies | `scripts/test-remote-mirror.sh` |

## Outcome and current state
The initial adapter is present. The **complete App has not built or run with these
changes**. Do not treat the feature as release-ready.

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
- Seven focused Swift Testing tests passed, including real TLS listener/connection
  tests for lazy capture, `PANE_BUSY`, raw input delivery, stop lifecycle, and wrong-key
  metadata denial. The Host test uses an injected terminal source, not an actual Ghostty surface.
- Production relay exercised under a real PTY: fragmented inbound frames, exact VT
  bytes, raw arrow/Ctrl-C/paste bytes, heartbeat response, and exit on disconnect passed.
- New adapter types passed Swift type checking with real Ghostty C headers and minimal
  surrounding App stubs. Modified Swift files passed syntax parsing. These checks do
  not replace compilation against the complete App.
- `make check` passed formatting stages, then stopped because `mise`/SwiftLint are absent.
- `make build-app` reached CLI dependency resolution. GitHub fetches were extremely
  slow and failed with HTTP/2 early EOF. Process-local HTTP/1.1 retry also stalled.
  Downloads were stopped after the user confirmed the proxy was currently unreliable.
- No GUI, two-App, LAN, IME, font scaling, or end-to-end history assertions were made.

## Deviations and remaining work
- Native TLS/TCP replaces the originally proposed WebSocket transport; no browser client.
- History is a separate retained-text view, not styled Ghostty scrollback replay.
- Reconnect currently means closing and re-adding the mirror; no automatic retry.
- Mirrors occupy the detail area individually; mixed local/remote split trees are not implemented.
- The pinned Ghostty backend requires a PTY; the internal app relay follows the upstream
  spike instead of modifying Ghostty's IO backend.
- Finish dependency resolution, install/use the repository build tools, run complete
  App compilation and lint, then verify real Host/Client surfaces and native UI.
- Check grid presentation, key focus/IME, and live/history switching in the actual App.
- Before publishing, pin Prowl's Ghostty submodule to a reachable bridge commit; the
  current local branch deliberately uses `PROWL_GHOSTTY_SOURCE_DIR` instead.
