import AppKit
import SwiftUI

struct WindowTabbingDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowTabbingView {
    WindowTabbingView()
  }

  func updateNSView(_ nsView: WindowTabbingView, context: Context) {
    nsView.disallowTabbing()
  }
}

final class WindowTabbingView: NSView, NSWindowDelegate {
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

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Prowl is a single-window app. Calling orderOut(nil) here breaks
    // fullscreen state and destroys the Ghostty Metal render layer when
    // terminal surfaces are closed, causing a black screen on re-show.
    // Just return false to keep the window visible.
    return false
  }
}
