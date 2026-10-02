import SwiftUI

/// Bridges reducer-driven Settings requests to SwiftUI's `openWindow` action.
///
/// Settings is a singleton `Window(_:id:)` scene. Keeping its presentation in
/// SwiftUI lets the scene own the native window lifecycle while reducer and
/// command-palette entry points can still surface it without reaching for
/// AppKit window management.
@MainActor
final class SettingsWindowOpener {
  static let shared = SettingsWindowOpener()

  private var opener: (() -> Void)?
  var hasRegisteredOpener: Bool {
    opener != nil
  }

  init() {}

  func register(_ opener: @escaping () -> Void) {
    self.opener = opener
  }

  @discardableResult
  func openSettingsWindow() -> Bool {
    guard let opener else { return false }
    opener()
    return true
  }
}

/// Registers SwiftUI's window-opening action from a live view host. The
/// registration is refreshed whenever the main window appears.
private struct SettingsWindowOpenerRegistrar: ViewModifier {
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      SettingsWindowOpener.shared.register(openWindow: openWindow)
    }
  }
}

extension View {
  func registersSettingsWindowOpener() -> some View {
    modifier(SettingsWindowOpenerRegistrar())
  }
}

extension SettingsWindowOpener {
  @discardableResult
  func register(openWindow: OpenWindowAction) -> Bool {
    register {
      openWindow(id: WindowID.settings)
    }
    return hasRegisteredOpener
  }
}
