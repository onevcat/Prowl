# 067.011 — Remote viewport scrolling

Status: Implemented and locally verified (2026-10-01); physical-device and remote-Host acceptance pending.

## Context

Mirror History reads a frozen Ghostty retained-text buffer. It cannot navigate
history owned by a full-screen application. Preserve History unchanged and add
direct, bounded up/down interaction with the live Host terminal on all clients.

## Design

- Advertise `remote-scroll`. A leased `scroll` control carries a request UUID and
  `up` / `down` direction, independent of `vt-v1` / `text-v1` representation.
- Host routes a small wheel movement through its own Ghostty surface, at
  the terminal center. Negotiated mouse / alternate-scroll modes remain owned
  by Ghostty; there are no agent-specific keys or dispatch completion receipts.
- Ghostty source and prebuilt artifacts remain unchanged. Existing wheel routing
  handles both application mouse/alternate-scroll input and native scrollback.
  Mobile text frames use the existing viewport text API. For terminal clients,
  active styled VT remains authoritative for display/input-mode negotiation.
- Clients explicitly opt into `viewport-text-v1` using `includeViewportText`.
  An optional plain-text viewport accompanies each VT frame with the same sequence,
  before the binary frame. It is displayed only after that frame is acknowledged.
  Native scrollback uses this plain overlay; the active viewport clears it. Older
  clients never receive this additional message. History stays unchanged.
- Native scrollback is detected using the visible geometry of ACTIVE `(0,0)`,
  including when that cell is blank or fully outside the viewport. Capture checks
  dimensions and geometry for concurrent resize; no agent identity is consulted.
  Physical-row reads preserve soft wraps in the Mac overlay. Original scrollback
  colors are unavailable through these public APIs, an accepted presentation tradeoff.
- A `scrollResult` identifies a fresh frame sequence after scrolling; this confirms
  terminal input and capture, not application-level page position or completion.
- Clients allow one scroll at a time and provide loading, bounded timeout,
  cancellation on disconnect/takeover, and explicit up/down buttons.
  No automatic retry of input after uncertain delivery.
- Superseded interaction: remote scrolling now uses explicit top-row buttons only.
  Wheel and touch gestures remain local; see [012](012-scroll-controls-and-report-feedback.md).
- Local Host and remote client share the live viewport. Page distance depends on
  application handling and configured wheel multiplier. This is not an independent archive.

## Verification plan

Cover wire controls, lease/capability checks, no-op scrolling, sequence correlation,
bounded loading, stale replies, reconnect and unchanged History. Exercise both
normal scrollback and alternate-screen input using isolated terminal fixtures.
Build macOS, iOS and Android; do not restart the user's active Host or submit a PR.

## Outcome

Implemented across the Host, macOS, iOS and Android. The Host injects one wheel
notch, allows changed captures after 200ms, and requests a forced fresh capture
at 800ms when the screen has not changed. Existing frame acknowledgement and
capture retries can delay delivery; 800ms is not a response deadline. Clients
stop loading after five seconds without replaying uncertain input.

Native Mac scrollback uses a selectable plain-text overlay with physical row
boundaries, including wide-character wraps. Reaching the active screen restores
the styled terminal. Overlay shortcuts preserve other input fields' focus. On
mobile, up completion anchors the readable viewport at the top and down at the
bottom. Interior drags remain local; long-press selection does not scroll the Host.
History retains its existing frozen-buffer paging behavior.

Verification covered 54 macOS protocol, lifecycle, state and real Ghostty
integration tests, plus a focused overlay keyboard regression. The integrations
exercise native scrollback, an alternate-screen application, text-v1 over TLS,
resize, blank/wide-character rows, frame pairing and the complete Mac pane view.
An isolated on-screen Mac fixture also verified the overlay and scroll controls.
iOS passed 64 cases / 70 parameterized runs on iPad, with additional iPhone
gesture checks. Android passed 36 unit tests (one existing optional TLS case
skipped), 12 emulator UI tests, Debug assembly and Android lint. Mac Debug,
iOS simulator and unsigned iPhoneOS arm64 Debug builds succeeded. The Ghostty submodule and bundled framework
remain unchanged.

Repository formatting, 210 script tests, performance-script tests, workflow naming
and the string-catalog check pass (script checks require Python 3.10 or newer).
Full repository lint remains blocked by five
pre-existing `legacy_swiftui_aspect_ratio` violations in `RepositoryIconImage.swift`;
the remote-scroll macOS files pass. No live Host was restarted and no PR was opened.
