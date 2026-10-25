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

final class WindowTabbingView: NSView {
  private var undoKeyMonitor: TerminalCloseUndoKeyMonitor?
  private let delegateProxy = MainWindowDelegateProxy()

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
    if window.delegate !== delegateProxy {
      // A proxy of an earlier view forwards to SwiftUI's delegate; take that one over
      // instead of chaining proxies.
      let current = window.delegate
      delegateProxy.forwardee = (current as? MainWindowDelegateProxy)?.forwardee ?? current
      window.delegate = delegateProxy
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

  static func shouldOrderOutOnClose(styleMask: NSWindow.StyleMask) -> Bool {
    !styleMask.contains(.fullScreen)
  }
}

/// Keeps the main window open when the user closes it, and forwards every other delegate
/// message to the delegate that SwiftUI installed. SwiftUI derives the scene phase and
/// other window state from that delegate, so it must keep receiving them.
final class MainWindowDelegateProxy: NSObject, NSWindowDelegate {
  // `NSWindow` sends delegate messages on the main thread only. The overrides below
  // inherit `NSObject`'s nonisolated declarations, so they cannot be main actor-isolated.
  nonisolated(unsafe) weak var forwardee: (any NSWindowDelegate)?

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if WindowTabbingView.shouldOrderOutOnClose(styleMask: sender.styleMask) {
      sender.orderOut(nil)
    }
    return false
  }

  nonisolated override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || forwardee?.responds(to: aSelector) == true
  }

  nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if let forwardee, forwardee.responds(to: aSelector) {
      return forwardee
    }
    return super.forwardingTarget(for: aSelector)
  }
}
