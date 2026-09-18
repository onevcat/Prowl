import AppKit

/// Catches the key that would undo or redo a close when no terminal surface
/// can take it (docs-ai 069.002).
///
/// A focused terminal handles Ghostty's `undo` / `redo` bindings itself. After
/// the last tab of a worktree closes, the terminal area is empty and nothing
/// receives ⌘Z: SwiftUI's Edit › Undo does not consult the window's undo
/// manager, so a local key monitor is the one place the key can be caught.
/// The monitor answers only for its owning window, leaves text editing its
/// own undo, and hands the event to Ghostty's app-level binding dispatch, so
/// the user's real bindings decide which key it is.
@MainActor
final class TerminalCloseUndoKeyMonitor {
  private var monitor: Any?

  /// `ownerWindow` is resolved per event: the owning view may not be in a
  /// window yet when the monitor is installed. `dispatch` returns `true`
  /// when the key undid or redid a close; only then is the event swallowed.
  init(
    ownerWindow: @escaping @MainActor () -> NSWindow?,
    dispatch: @escaping @MainActor (NSEvent) -> Bool
  ) {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard Self.shouldDispatch(event, ownerWindow: ownerWindow()) else { return false }
        return dispatch(event)
      }
      return handled ? nil : event
    }
  }

  isolated deinit {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  /// The event must belong to the owning window, and that window's first
  /// responder must not own undo itself: a terminal answers the key through
  /// Ghostty's own binding, a text field keeps the standard text undo.
  static func shouldDispatch(_ event: NSEvent, ownerWindow: NSWindow?) -> Bool {
    guard let ownerWindow, let eventWindow = event.window, eventWindow === ownerWindow else { return false }
    return !firstResponderOwnsUndo(ownerWindow.firstResponder)
  }

  nonisolated static func firstResponderOwnsUndo(_ responder: NSResponder?) -> Bool {
    responder is GhosttySurfaceView || responder is NSText
  }
}
