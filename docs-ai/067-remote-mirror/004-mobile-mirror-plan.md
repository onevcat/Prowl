# 067.004 — Mobile mirrors and explicit takeover

Status: In progress on `feat/mobile-mirror`. See [005](005-mobile-mirror-foundation.md) for implemented boundaries.

## Context

Native mobile clients need reflowable text from an existing terminal, while Mac
clients retain the Host grid. An unattended Host must allow explicit remote
takeover without requiring local approval. The Host continues owning the process.

## Design

- Extend `MirrorProtocol.swift` with a version-one discovery handshake that
  advertises version two capabilities. Preserve the existing TLS PSK encoding.
- Keep one connection per pane. Validate a subscription identity on every input,
  acknowledgement and history request. Explicit takeover replaces the owner;
  retry uses if-free and never steals the pane.
- Capture the replacement frame before changing ownership. A failed capture must
  leave the current owner intact. Delayed close callbacks only remove their peer.
- Add plain ACTIVE text through `GhosttyMirrorPaneSource.swift` using the existing
  text API. Mobile clients replace the displayed text; cleared output is not an
  archive. Do not interpret terminal control bytes as Markdown.
- Preserve the Mac replica after disconnection and expose a reason-specific
  recovery action. Remember verified connection settings; store keys securely.
- Replace system sharing with direct pairing-key copy. Add an optional named AI
  control console using existing Agent profiles and bundled CLI documentation.
- Mobile input requires both reliable idle evidence and a clean input target.
  Never inject into an uncertain prompt or replay a submission after disconnection.
- History needs a validated bound before terminal capture. A post-capture suffix
  is not a memory bound. Unsupported capture paths remain explicitly unavailable.

## Validation

First cover compatibility, takeover failure, stale subscription traffic, text
replacement and backpressure with focused tests. Follow with real Host/iPad
transport, native UI, keyboard and Agent integration checks. Do not equate a
compiled scaffold or a fake transport test with end-to-end verification.

The iPad app is developed in a separate native repository. Android follows the
iPad path; iPhone is optional. No new Ghostty implementation is planned.
