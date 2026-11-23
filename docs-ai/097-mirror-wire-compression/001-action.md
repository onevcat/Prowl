# 097 — Mirror wire compression: Action Log

## Timeline
| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-22 | `deflate-v1`: Host compression on request, iOS and Mac clients ask for it | this PR |

## Outcome & current state (as of 2026-11-22)

- `Mirror/Shared/MirrorWireCompression.swift`: `Deflater` and `Inflater` over the system zlib
  (raw DEFLATE, 32 KB window, sync flush per message), and `expand(_:with:limit:)`, which
  inflates a type-3 payload and rejects a nested one or more than `MirrorWire.maximumPayload`.
- `MirrorWire.payload(_:)` returns the unframed payload on both sides; the Mac
  `MirrorWire.encode(_:compressor:)` frames it compressed or plain.
- Mac `MirrorConnection`: `startCompressing()` (once, later calls do nothing) compresses every
  later send; every received payload goes through `expand`; `compressedMessagesReceived`
  counts compressed arrivals for tests.
- `MirrorHost` lists `deflate-v1` and turns compression on for a peer on `compress`.
- Clients ask once per connection, right after the first `panes` and before their other
  requests: iOS `MirrorHostSession` (roster) and `MirrorSession` (pane), and the Mac
  `MirrorClient`. The iOS `MirrorConnection` only inflates; clients never compress.
- Wire documentation and a cross-implementation vector (made by Python's zlib) in
  `docs/remote-mirror-wire.md`, tested by the Mac and iOS `MirrorWireVectorTests` /
  `MirrorWireCompressionTests`.

## Device measurement (iPhone One, isolated Debug Host with 5 panes)

The same Host, first with the iOS build from `main` (never asks), then with this build. Bytes
the Host sent on its Mirror connections, from `nettop`:

| Scenario | Plain | Compressed | Change |
| --- | --- | --- | --- |
| Idle on the agents list, per minute | 59,194 B | 3,465 B | −94% |
| Opening a terminal pane (6 s, roster included) | 13,309 B | 4,280 B | −68% |
| 22 s of terminal output (`ls -la /usr/bin \| head -40` each second) | 106,357 B | 10,547 B | −90% |

The terminal output repeated, which favors the shared window. A chat open was not measured on
the device; conversation event JSON compresses 3.7–4× in gzip (fixtures).

## Deviations from plan

- The Mac client (`MirrorClient`) asks for compression too: it shares the Mac
  `MirrorConnection`, so it needed one request.

## Open questions

- Android client: not changed; the vector in `docs/remote-mirror-wire.md` is what it must read.
