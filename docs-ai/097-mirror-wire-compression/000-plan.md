# 097 — Mirror wire compression: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-22 |
| **Primary PRs** | (fill in) |
| **Related** | [096-mirror-remote-access](../096-mirror-remote-access/000-plan.md), `docs/remote-mirror-wire.md` |

## Background

Mirror messages are uncompressed. Measured on iPhone One against a Host with 4 panes
(2026-11-22, from the phone's per-connection byte counts):

| Traffic | Now |
| --- | --- |
| Roster: the full pane list every 3 s while the app is open | 2.2 KB per list, 40–60 KB/min, about 3 MB/h |
| Opening a long chat (≤500 events) | 370–460 KB, sent again on every reopen |

096 may carry this traffic through our DERP relays, where every byte costs.

## Goals

- Compress Host → client traffic on connections whose client opts in.
- Old clients (iOS before this change, Android, the Mac client) and old Hosts keep working
  unchanged.

### Non-goals

- Client → Host compression: that traffic is small (commands, acknowledgements).
- Changing what is sent (roster push instead of polling, phone-side chat cache, smaller first
  page). Each can follow separately.

## Design

- **Capability** `deflate-v1` in the Host's `panes` capabilities.
- **Opt-in**: a client that sees it sends `compress` (a JSON control, once per connection)
  before anything else it wants compressed, for example before `subscribe`. Hosts without the
  capability never get it, because they close on unknown controls.
- **Frames**: payload type `3` = a raw DEFLATE block of one complete payload of type 0, 1 or 2,
  ended with a sync flush (`Z_SYNC_FLUSH`). One compression stream per connection and
  direction keeps its window across messages, so a roster that barely changed costs about
  30 bytes instead of 2.2 KB. The Host compresses every frame after the opt-in.
- **Receiver**: one inflate stream per connection, created on the first type-3 frame. The
  inflated payload is decoded as today. An inflate error, or a payload over
  `MirrorWire.maximumPayload`, closes the connection (decompression-bomb bound).
- **Code**: `Mirror/Shared/MirrorWireCompression.swift` (deflate and inflate streams over the
  system zlib, `import zlib`), compiled by the Mac app and the iOS app. `MirrorConnection` on
  each side owns its streams; `MirrorHost` turns compression on per peer.
- **Contract**: a wire vector (two consecutive compressed frames of a known message) in the
  Mac and iOS `MirrorWireVectorTests`, so another client (Android) can implement it later.

## Measured target (prototype with Python zlib, same message)

| | Now | Per message | One stream per connection |
| --- | --- | --- | --- |
| Roster per list | 2,200 B | 652 B | 650 B, then about 33 B |
| Roster per minute | 44 KB | 13 KB | 1.3 KB |
| Chat open (event JSON) | ~460 KB | — | ~120 KB (gzip ratio 3.7–4×) |

## Alternatives & decisions

- Per-message `NSData.compressed(using: .zlib)`: simpler, but saves only 70% of the roster
  instead of 97%, because each list starts from an empty window.
- TLS-level or `Network.framework` compression: not available.
- Compress only above a size threshold: needless with a shared stream; tiny messages cost a few
  bytes.

## Verification

- Unit: stream round trip over many messages; the wire vector; a corrupt or oversized type-3
  frame closes the connection; a client that never opts in gets only uncompressed frames;
  `compress` from a client is accepted once.
- Device: iPhone One with an isolated Debug Host, byte counts from the phone's unified log
  before and after (roster per minute, chat open).

## Amendments
