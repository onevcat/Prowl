import AppKit
import Testing

@testable import supacode

/// Regression guard for the Shelf-entry focus bug: when a
/// `WindowFocusObserverNSView` is torn off its host window (e.g. one
/// SwiftUI subtree is swapped for another that continues to observe the
/// same `WorktreeTerminalState`), the teardown must NOT fire an
/// "inactive" activity callback. An inactive callback would overwrite
/// the shared state's cached window-key flag and demote the surface's
/// focused bit even though the window is still key.
@MainActor
struct WindowFocusObserverViewTests {
  @Test func detachFromWindowEmitsNothingNew() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    let observer = WindowFocusObserverNSView()
    var emits: [WindowActivityState] = []
    observer.onWindowActivityChanged = { emits.append($0) }

    // Attach: the observer may emit the window's current activity state
    // once (headless test windows report key=false, visible=false — so
    // that initial emit is itself "inactive" here; that's fine). We
    // capture the count so the detach assertion compares against this
    // baseline instead of against an idealized non-inactive list.
    window.contentView?.addSubview(observer)
    let emitsAtAttach = emits.count

    // Detach: no new emit should fire, regardless of what the window's
    // current state is. Prior to the fix, `updateObservers` called
    // `emitActivityIfNeeded(force: true)` on detach, which always sent
    // a (key=false, visible=false) inactive signal and poisoned the
    // shared `WorktreeTerminalState`'s cached window-key flag.
    observer.removeFromSuperview()
    let emitsAfterDetach = emits.count
    #expect(
      emitsAfterDetach == emitsAtAttach,
      "Detach must not emit new activity. attach=\(emitsAtAttach), afterDetach=\(emitsAfterDetach)"
    )
  }
}
