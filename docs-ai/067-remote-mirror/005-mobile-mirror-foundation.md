# 067.005 — Mobile mirror foundation

## Implemented behavior

Version-one discovery now negotiates version two without changing TLS PSK bytes.
Text and VT subscriptions share exclusive ownership. A takeover prepares its first
frame before revoking the previous owner. Version-two input, ACK and history use
the current subscription ID; the internal Mac relay carries that identity back.
Text subscriptions cannot inject raw terminal input.

Mac clients expose explicit takeover and if-free Retry, retaining the last replica
after disconnection. Host stop, pane closure and takeover have separate reasons.
Verified connection information is stored in Keychain; the add form prefills it
without connecting. Pairing-key copy uses the clipboard directly.

The optional AI control console reuses Agent Profile preparation, hooks and launch.
Its named tab is protected from repository pruning and ordinary layout persistence.
List/target/Agent context builders include its internal worktree. The console uses
an independent CLI socket routed to the same app; hooks and startup documentation
refer to that instance. It has a separate terminal window, launch errors and restart.
Stopping sharing cancels an unfinished launch but does not terminate an existing
console. App exit stops its CLI endpoint.

## Verification on 2026-09-09

- App Debug builds with the sibling Ghostty override. No new Ghostty changes.
- Focused protocol, Host, connection, console-plan and ProjectWorkspace tests pass.
- The real Ghostty integration test covers terminal output, local/remote input,
  takeover, old-owner input suppression, if-free Retry, explicit retake, retained
  last frame, and Host process survival after unsubscribe/stop.
- `make check` passes after minimal baseline Swift 6 closure and SwiftUI API fixes.
- CLI build, smoke and 112 CLI integration tests pass. Two existing workflow export
  unit tests fail with `exportFailed`, including a standalone rerun. Their production
  export implementation was not changed by this feature; the failure remains open.
- Native Mac UI automation was skipped because agent-ctrl is absent.

The separate iPad implementation passes native simulator transport tests using a
copy of this Host implementation with a deterministic text source, session/reading
tests, and a portrait/landscape connection-form UI test. This is distinct from a
physical iPad connected to a real Ghostty Host.

## Remaining boundaries

Mobile Agent submission and history are not enabled. Safe idle/clean-editor
evidence and a pre-capture history bound still need implementation and validation.
The console's real Agent startup, instruction loading, process-exit reporting and
window UX are not yet accepted by an end-to-end test. Saved console configuration,
credential editing, complete foreground recovery UX and hardware double-Return
also require follow-up. Android is not implemented. This is an implementation
checkpoint, not acceptance of the complete mobile plan.
