import AppKit
import SwiftUI

struct WindowTabbingDisabler: NSViewRepresentable {
  /// Receives the undo/redo key when no terminal surface can take it
  /// (docs-ai 069.002); returns `true` when a close was undone or redone.
  var dispatchUndoRedoKey: @MainActor (NSEvent) -> Bool

  func makeNSView(context: Context) -> WindowTabbingView {
    WindowTabbingView()
  }

  func updateNSView(_ nsView: WindowTabbingView, context: Context) {
    nsView.installUndoKeyMonitor(dispatch: dispatchUndoRedoKey)
    nsView.disallowTabbing()
  }
}

final class WindowTabbingView: NSView, NSWindowDelegate {
  private var undoKeyMonitor: TerminalCloseUndoKeyMonitor?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    disallowTabbing()
  }

  func disallowTabbing() {
    guard let window else { return }
    window.tabbingMode = .disallowed
    window.identifier = NSUserInterfaceItemIdentifier(WindowID.main)
    // Persist the main window's position and size across launches. Idempotent:
    // re-associating the same autosave name on later passes is a no-op.
    window.setFrameAutosaveName(NSWindow.FrameAutosaveName(WindowID.main))
    window.isExcludedFromWindowsMenu = true
    if window.delegate !== self {
      window.delegate = self
    }
  }

  /// One monitor for the view's lifetime; SwiftUI re-runs `updateNSView`
  /// often and the closure it hands over is equivalent every time.
  func installUndoKeyMonitor(dispatch: @escaping @MainActor (NSEvent) -> Bool) {
    guard undoKeyMonitor == nil else { return }
    undoKeyMonitor = TerminalCloseUndoKeyMonitor(
      ownerWindow: { [weak self] in self?.window },
      dispatch: dispatch
    )
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if Self.shouldOrderOutOnClose(styleMask: sender.styleMask) {
      sender.orderOut(nil)
    }
    return false
  }

  static func shouldOrderOutOnClose(styleMask: NSWindow.StyleMask) -> Bool {
    !styleMask.contains(.fullScreen)
  }
}
