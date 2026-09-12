# Experimental mirror wire contract

All integers in binary packets are unsigned big-endian. A packet is `length:u32`,
then `kind:u8`, then payload. Length includes kind, excludes the four-byte prefix,
and must be 1…8,388,608. Unknown kinds, malformed UTF-8, missing required fields and
invalid payloads close the connection. This revision has no compatibility negotiation.

| Kind | Payload |
| --- | --- |
| 0 | UTF-8 JSON control message |
| 1 | subscription UUID:16 raw bytes, sequence:u64, columns:u32, rows:u32, raw VT bytes |
| 2 | subscription UUID:16 raw bytes, sequence:u64, columns:u32, rows:u32, truncated:u8, UTF-8 text |

Sequence starts at 1. VT grid dimensions are 1…1000. Text dimensions allow zero for
an unspecified test/source grid; production Ghostty sources supply actual sizes.
Truncated is exactly 0 or 1. Empty text is a replacement. JSON frame/textFrame cases
are rejected: frames must use their binary encoding. No Base64 frame content is sent.

Control JSON follows Swift Codable's associated-value enum shape: no-payload list
is `{"list":{}}`; a subscribe is `{"subscribe":{"_0":{"paneID":"UUID",
"representation":"text-v1","intent":"ifFree"}}}`. The enum and payload structs in
`MirrorProtocol.swift` define required fields. Both repositories verify identical
fixed-byte vectors, independent of encode/decode round-trip tests.

Controls: challenge, authenticate, pair, paired, authenticated; list, panes;
subscribe, subscribed, acknowledge, input, refresh; history, historyPage; command,
commandResult, commandReceipt; failure, ended, ping, pong. There is no private
Agent-state or private submission control. Command envelopes preserve the public
CLI JSON and UUID request ID. See the feature documentation for command scope.

## Authentication and lifecycle

TLS uses ECDHE-PSK with ChaCha20-Poly1305. Enrollment uses identity `pair` and the
normalized temporary code. Runtime connections use the device UUID identity and
32 random secret bytes. No plain-PSK legacy suite is enabled.

TLS PSK membership alone is not treated as a device identity. Host sends its stable
hostID and a fresh 32-byte nonce. Device proves its secret using HMAC-SHA256 over
UTF-8 `device:HOST_UUID:DEVICE_UUID:` followed by nonce bytes. Enrollment proves the
code over `pair:HOST_UUID:DEVICE_NAME:` plus nonce. UUID strings use the Foundation
uppercase canonical spelling. Proofs are Base64 Data fields in control JSON.
Different purpose, Host, identity or nonce cannot reuse a proof.

Before proof validation only authentication/enrollment and connection heartbeats
are accepted. Enrollment persists Host-generated device ID/key before replying;
the window is consumed before another peer can enroll. Client saves before closing
the enrollment connection and reconnecting with its device credential. Host names
are display metadata, never identity. Authentication has a five-second deadline.
Failure accounting and pending TLS pools are bounded. No secret is logged.

A subscribed connection has exactly one lease. Every input, ACK, history request,
refresh and targeted command must match it. Takeover revokes the previous connection.
Delayed commands recheck authorization immediately before delivery. A command result
is not a terminal/frame acknowledgement. One unacknowledged frame per subscriber
bounds backpressure; an ACK must exactly match its outstanding sequence.

History ID/offset refer to one frozen snapshot, with fixed total and capture time.
Pages cannot overlap, skip or exceed the total byte budget. Heartbeats run every
two seconds; eight seconds without inbound traffic ends an established connection.
