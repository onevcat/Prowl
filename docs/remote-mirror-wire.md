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
subscribe, subscribed, acknowledge, input, refresh, scroll, scrollResult, viewport; history, historyPage; command,
commandResult, commandReceipt; failure, ended, ping, pong. There is no private
Agent-state or private submission control. Command envelopes preserve the public
CLI JSON and UUID request ID. See the feature documentation for command scope.

The `launch-profile` capability permits Profile-backed background tab creation.
`launch-shell` additionally permits a background `create tab` with no `launch`
field. Neither capability permits arbitrary initial Shell input. Mac clients gate
Shell creation on `launch-shell`; existing Profile requests remain unchanged.
The remote `list` command result adds optional `data.worktrees`, using the same
worktree fields as `data.items[].worktree`, to include known worktrees without
terminal panes. Clients without that field can still use worktrees from `items`.

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

A subscribed connection has exactly one lease. Every input, scroll, ACK, history request,
refresh and targeted command must match it. Takeover revokes the previous connection.
Delayed commands recheck authorization immediately before delivery. A command result
is not a terminal/frame acknowledgement. One unacknowledged frame per subscriber
bounds backpressure; an ACK must exactly match its outstanding sequence.

History ID/offset refer to one frozen snapshot, with fixed total and capture time.
Pages cannot overlap, skip or exceed the total byte budget. Heartbeats run every
two seconds; eight seconds without inbound traffic ends an established connection.

## Remote scroll

The additive `remote-scroll` capability permits scroll controls for both `vt-v1`
and `text-v1`. Clients without that capability must not send scroll controls.
Binary frame formats remain unchanged.

```json
{"scroll":{"_0":{"requestID":"UUID","direction":"up","subscriptionID":"UUID"}}}
{"scrollResult":{"_0":{"requestID":"UUID","sequence":42,"subscriptionID":"UUID"}}}
```

Direction is exactly `up` or `down`. Native scrollback moves by the Host pane
height minus three rows (at least one row). Application-owned scrolling receives
precision wheel input at the terminal center, adjusted for known Agent wheel units
and reserved rows. Application behavior and Host precision-scroll settings can
change the distance; this is not a fixed page-size contract. Mobile live text uses
the Host viewport; retained-text History capture remains unchanged.

There is one pending scroll per subscription. After applying input, Host waits
at least 200 ms and prefers a changed capture; after 800 ms it requests a fresh
frame even if unchanged. Existing frame acknowledgement backpressure still applies. It
sends `scrollResult` after that frame on the same ordered connection. `sequence`
identifies the fresh frame, not an application-level acknowledgement: terminal
applications may redraw later or ignore the input. Clients wait for the correlated
frame and result, allow five seconds, and never replay scroll input automatically.
Mac additionally waits for its display relay to acknowledge that frame.

`SCROLL_UNAVAILABLE` and `SCROLL_BUSY` are recoverable `failure` messages carrying
the subscription ID and additive optional `requestID`; only a matching pending
scroll is failed. Delayed results/errors cannot complete a newer scroll. Disconnect,
takeover and a replacement subscription clear pending local waits. Duplicate IDs
for the current pending or most recently completed scroll never inject input twice.
No Agent dispatch or Agent-generated completion receipt participates in scrolling.

## Scroll boundary metadata

`scroll-state-v1` is additive and requires `includeScrollState: true` on subscribe.
Only opted-in clients receive `scrollState` before every corresponding VT/text
frame, carrying `subscriptionID`, `sequence`, and optional `atTop` / `atBottom`.
Only `true` disables the relevant direction; null/missing means unknown. Clients
commit state with the matching frame (after display relay acknowledgement on Mac),
validate lease and sequence, and reset on replacement subscriptions. Boundary-only
changes participate in frame change detection. Binary frame formats are unchanged.

The Host derives native scrollback boundaries from existing SCREEN/ACTIVE geometry.
Mouse-captured TUI input and ranges that cannot be proven return unknown. No-op
scrolling is never treated as proof of reaching an application-owned boundary.

The Mac display relay suppresses canonical DEC mode enables 1004, 2031 and 2048
from snapshot replay. Focus, color and size reports belong to the original Host
terminal; enabling them in a replica would manufacture input sent back to Host.
Keyboard, paste and mouse input modes remain intact. This changes presentation,
not remote frame encoding or the original terminal state.

## Native scrollback text for terminal clients

`viewport-text-v1` is a separate additive capability. A terminal client opts in
with `includeViewportText: true` in its `subscribe` payload. Without both opt-in
and Host support, the Host never sends the additional control message.

```json
{"viewport":{"_0":{"text":"earlier terminal rows","sequence":42,"subscriptionID":"UUID"}}}
```

This control precedes each corresponding binary VT frame on the same ordered
connection. Its sequence and lease must match that frame. Missing/null `text`
selects the original styled active screen; a string, including an empty string,
selects a plain native-scrollback overlay. The client commits this presentation
only with the matching relay acknowledgement. The VT frame and its input modes
remain intact underneath. Native viewport text participates in Host change
detection even when the active VT bytes are unchanged. Binary formats are unchanged.

Per-row viewport text preserves physical wrapping. The source checks terminal
geometry before/after capture and retries transient resize mismatches on later
polls, with a finite retry bound. This is not an atomic terminal checkpoint or
an independent history archive, and does not export scrollback colors.

## Interactive Agent input

A Host advertising `agent-input` accepts structured `agentsInput` with the same
`{pane, prompt}` payload as `agentsDispatch`. The pane must be a UUID owned by the
current authenticated subscription. The command is routed as `agents.input`; it
uses the guarded paste/Enter path without creating or mutating task dispatch records or
injecting completion instructions. Unlike `agentsDispatch`, it does not wait for the turn
to end: a working agent takes the text as typed input. A blocked agent refuses it with
`DISPATCH_TARGET_BUSY`. A runtime `needs-input` signal refuses it only when the screen
detector also reports blocked, because the signal stays until the turn ends. `text-v1`
remains the mobile representation. `agentsDispatch` retains its automation semantics.

Success has `command: "agents.input"`, schema `prowl.cli.agents.input.v1`, and
`data.input` containing UTF-8 `bytes`, `characters`, `source`, and
`trailing_enter_sent`. Clients verify the submitted byte count and Enter flag before
clearing that draft revision. Failed/uncertain delivery retains the draft;
`SEND_FAILED` is uncertain, not permission to replay. Existing request-ID deduplication
and `commandReceipt` recovery apply. A missing `agent-input` capability requires a
Host update; clients must not silently fall back to `agentsDispatch` or raw input.

## QR enrollment payload (version 1)

The QR carries UTF-8 JSON, not a URL or a transport message:

```json
{"type":"prowl-mirror-pairing","version":1,"address":"192.168.1.20","port":7880,"code":"ABCDEFGH","expiresAt":1800000060}
```

`address` is a numeric IPv4/IPv6 address reachable from the phone, never a wildcard
or loopback. `port` is an integer in 1...65535. `code` uses the existing eight-symbol
normalized pairing alphabet. `expiresAt` is an integer Unix time in seconds.
Scanners accept at most 2048 UTF-8 bytes, reject invalid/expired payloads and create
a fresh connection without a saved credential. Host still enforces expiry and
single use. The payload is not persisted or logged; transport authentication and
credential storage are unchanged. Version 1 is generated by Host and parsed by
both mobile apps. Cameras are not required for manual enrollment.

### Optional Mac styled scrollback

`styled-scrollback-v1` is an opt-in capability for `vt-v1` subscriptions with
`includeViewportText: true` and `includeStyledScrollback: true`. The correlated
`viewport` message may contain `styledScrollback: { bytes, rowOffset }`.
`bytes` uses Codable Data/base64 encoding; archives are capped at 2 MiB and
zero-based offsets at 5,000 rows. Missing metadata retains the existing plain-text
fallback. No new messages are sent to text-v1 subscribers. Binary VT frames and
mobile wire behavior are unchanged.

## Pane roster fields

The `panes` reply also carries what a client needs to show the roster the way the Mac
sidebar does (docs-ai 089). All fields are optional; older clients ignore them and older
Hosts leave them out.

| Field | Content |
| --- | --- |
| `hostName` (on `panes`) | The Mac's computer name |
| `displayState` | `working`, `blocked`, `done` (idle and not looked at yet) or `idle`, as Prowl for Mac shows the agent |
| `stateChangedAt` | When the agent state last changed, ISO 8601 with milliseconds |
| `tabTitle`, `worktreeName` | The Mac tab title and the worktree name |
| `repositoryColor` | The repository color: a preset name (`red`, `orange`, `yellow`, `green`, `mint`, `cyan`, `blue`, `purple`, `pink`, `gray`) or `#RRGGBB` |
| `projectOrder`, `groupName` | The project's position in the sidebar and the name of the group that holds it; `projectName` is the sidebar name |

## Answering prompts (`prompt-respond`)

While an agent is blocked on a choice menu (Claude Code's permission and AskUserQuestion
dialogs, including the multi-select dialog and the "Review your answers" page, and Codex's
approval), the Host reads the menu from the pane's screen and sends it on `conversation-v1` as
`prompt.opened` with `source: "screen"` (docs-ai 089 S4). The prompt id is
`screen:<hash>.<n>`. The hash covers the question, the detail (such as the command to approve,
or the answers a review page submits), and every answer with its description. It does not cover
the highlight, the boxes of a multi-select menu, or text typed into the "Type something" row, so
these changes keep the prompt. `<n>` counts openings, so the same menu shown twice is two
prompts. `choices[].id` is the option's number on screen. `freeform` says the menu also has
"Type something" / "Chat about this" rows, which are not offered.

A multi-select menu has `multiSelect: true` and `choices[].checked`. When a box changes, the
Host sends `prompt.opened` again with the same id and the new boxes; a client replaces the open
prompt with that id. Choosing an option toggles its box and leaves the menu open. The choice
`submit` presses the menu's Submit row; Claude then shows its review page, which is a new
prompt.

The prompt resolves when the phone's answer is pressed, with `allowed`, `denied` or `answered`
and `decidedBy: "mirror"`. Otherwise it resolves when the menu leaves the screen, with
`unknown`.

A `text-v1` subscription that sets `includeScreenPrompt: true` on subscribe gets the same menu
as a `screenPrompt` message, so the Terminal view can answer it too:

```json
{"screenPrompt":{"_0":{"prompt":{"id":"screen:…","kind":"question","title":"…","choices":[…],"freeform":false},"subscriptionID":"UUID"}}}
```

The Host sends it when the menu opens, changes or closes (`prompt` absent). It needs no
acknowledgement. A Host that does not know the flag ignores it and sends no `screenPrompt`.

A client with the `prompt-respond` capability answers with a command on the subscription that
mirrors the pane:

```json
{"command":{"_0":{"subscriptionID":"UUID","commandRequest":{"requestID":"UUID","request":{"output":"json","command":{"promptRespond":{"_0":{"pane":"UUID","prompt":"screen:…","choice":"2"}}}}}}}}
```

The Host answers only the prompt that is open now. No IME text or local edit may be pending
(2 s). Before every key, it checks again that:

- the connection still holds the lease;
- the prompt is still open and the agent is still blocked;
- nobody started editing on the Mac;
- the screen still shows the same prompt.

It moves the highlight one row at a time, waits for the move, and presses Enter on the chosen
row. It never retries. Refusals use the common error envelope with `PROMPT_CLOSED`,
`PROMPT_CHANGED`, `PROMPT_CHOICE_INVALID`, `HOST_EDITING` or `DELIVERY_UNCERTAIN`.

## Keys for agent panes (`agent-keys`)

A client with the `agent-keys` capability can press navigation and control keys in the agent
pane it mirrors (docs-ai 089 S5): the iOS Terminal key bar and Stop. The command is
`agentKeys {pane, keys}`. `keys` holds 1 to 8 of `esc`, `ctrl-c`, `tab`, `shift-tab`, `up`,
`down`, `left`, `right` and `enter`. `ctrl-c` can only be the last key, because it may end the
agent. Printable text is never accepted; it goes through
`agents.input` with its readiness checks. The Host refuses panes without a detected agent and
panes with IME text or a local edit in the last 2 s (`KEYS_REFUSED`). It then presses the keys
one at a time. Before each key, it checks that the connection still holds the lease, that the
same agent still runs in the pane, and that nobody started editing on the Mac. A refusal after the first key says how many keys were
pressed.

## Conversation stream (`conversation-v1`)

`conversation-v1` is a third `subscribe` representation (capability `conversation-v1`,
docs-ai 087). It carries the agent's own transcript as normalized events instead of the
terminal screen: turns, user and assistant messages, tool start/end pairs with bounded
output and diffs, prompts that need a person, agent status, session changes, and notices.
Each `panes` descriptor says whether a pane can serve it (`conversation`: `available`,
`pending` while the Host knows the agent but not its transcript yet, or `unsupported`),
plus the detected `agent` and its `agentState`. Subscribing to an unsupported pane fails
with the recoverable `CONVERSATION_UNSUPPORTED` without closing the connection.

```json
{"subscribe":{"_0":{"paneID":"UUID","representation":"conversation-v1","intent":"ifFree","since":41}}}
{"conversationSnapshot":{"_0":{"events":[…],"gap":false,"sequence":57,"subscriptionID":"UUID","session":{"id":"…"}}}}
{"conversationEvents":{"_0":{"events":[…],"sequence":60,"subscriptionID":"UUID"}}}
{"acknowledge":{"_0":{"sequence":60,"subscriptionID":"UUID"}}}
```

After `subscribed`, the Host sends one `conversationSnapshot`: every event it retains after
`since` (or the whole retained segment without `since`), oldest first. `gap` is true when
events between `since` and the first one were dropped. `session` names the session the
retained events belong to (id, cwd, model, title, cost), kept by the Host even after the
`session.started` event itself was evicted; nil between sessions. Further events arrive in
`conversationEvents` batches on the same ordered connection. One batch is outstanding at
a time: the client acknowledges a non-empty snapshot or batch with its `sequence`, and a
wrong acknowledgement closes the connection. A batch whose events start after a gap
arrives as a `conversationSnapshot` with `gap: true` instead.

An event is `{"seq","ts","kind","source","data"}`. `seq` is monotonic per pane for the life
of the Host run, including across session changes; `ts` is an ISO 8601 timestamp with
milliseconds; `source` names the Host input (`transcript`, `hook`, `osc`, `native`,
`screen`, `host`); `data` is the payload family that `kind` selects. Clients ignore kinds
they do not know. Kinds: `session.started` / `session.updated` / `session.changed` /
`session.pending` / `session.ended`, `turn.started` / `turn.completed`, `user.message` /
`user.queued` / `user.unqueued`, `assistant.message` / `assistant.reasoning`,
`tool.started` / `tool.completed`, `agent.status`, `prompt.opened` / `prompt.resolved`,
`context.compacted`, `subagent.started` / `subagent.completed`, `notice`. Long text is
bounded (`{"text","truncated","totalBytes"}`); reasoning content is never sent. The Swift
model is `Mirror/Shared/MirrorConversationEvent.swift`, compiled by the Mac app and the iOS
client; both pin the same JSON vectors.

A `session.changed` or `session.pending` event starts a new segment: the Host restates
the current `agent.status` and the following `session.started` describes the new
transcript. A client that cannot tell which session it shows should fall back to the
Screen view (`text-v1`). The Host keeps a pane's conversation feed for ten minutes after
its last subscription ends, so a reconnect with `since` resumes without a gap; the same
connection may subscribe its own pane again with another representation to switch views.
`input` and `scroll` are not accepted on a conversation subscription; `agents.input`
commands are.
