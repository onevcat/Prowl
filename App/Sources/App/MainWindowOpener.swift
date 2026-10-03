import SwiftUI

/// Bridges AppKit-side "bring the main window back" requests to SwiftUI's
/// `openWindow` action.
///
/// The main window is a singleton `Window(_:id:)` scene. SwiftUI tears its
/// `NSWindow` down when the window closes, and on a macOS restart relaunch the
/// scene is often not recreated at all (the app launches with zero windows). A
/// bare `NSApp.activate(ignoringOtherApps:)` cannot bring back a scene SwiftUI
/// has torn down; only `openWindow(id:)` rebuilds it. Until #297 this only
/// happened implicitly when `applicationShouldHandleReopen` returned `true`
/// (Dock icon click); activation paths that do not trigger reopen, such as
/// Cmd-Tab, Mission Control, CLI `open`, and menu commands, left the app stuck
/// windowless.
///
/// SwiftUI registers the opener from both the app command tree and the main
/// window content. The command registration is important for loginwindow
/// relaunches that start the process with zero windows: the main window content
/// never appears, so an `onAppear`-only registration cannot recreate it.
/// `NSApplication.surfaceMainWindow()` then calls `openMainWindow()` from any
/// path that finds no existing main window.
@MainActor
final class MainWindowOpener {
  static let shared = MainWindowOpener()

  private var opener: (() -> Void)?
  var hasRegisteredOpener: Bool {
    opener != nil
  }

  init() {}

  func register(_ opener: @escaping () -> Void) {
    self.opener = opener
  }

  /// Requests a new main window. Returns `false` when no opener has been
  /// registered yet (e.g. the main window has never appeared this launch), so
  /// callers can fall back to AppKit's default reopen handling.
  @discardableResult
  func openMainWindow() -> Bool {
    guard let opener else { return false }
    opener()
    return true
  }
}

/// Registers SwiftUI's `openWindow` action with `MainWindowOpener.shared` so
/// AppKit paths can recreate the main window. Attach to the main window's
/// content; registration refreshes on every appearance.
private struct MainWindowOpenerRegistrar: ViewModifier {
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      MainWindowOpener.shared.register(openWindow: openWindow)
    }
  }
}

extension View {
  func registersMainWindowOpener() -> some View {
    modifier(MainWindowOpenerRegistrar())
  }
}

extension MainWindowOpener {
  @discardableResult
  func register(openWindow: OpenWindowAction) -> Bool {
    register {
      openWindow(id: WindowID.main)
    }
    return hasRegisteredOpener
  }
}
