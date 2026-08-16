import AppKit
import SwiftUI

internal struct CleanWindowConfigurator: NSViewRepresentable {
  internal func makeNSView(context: Context) -> CleanWindowConfigurationView {
    CleanWindowConfigurationView()
  }

  internal func updateNSView(_ view: CleanWindowConfigurationView, context: Context) {
    view.applyConfiguration()
  }

  internal static func configure(_ window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    // A hidden titlebar still makes NSThemeFrame consume its hit-test region.
    window.styleMask.remove(.titled)
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    window.isMovableByWindowBackground = false
    window.collectionBehavior.subtract([.fullScreenAuxiliary, .fullScreenNone])
    window.collectionBehavior.insert(.fullScreenPrimary)
  }
}

internal final class CleanWindowConfigurationView: NSView {
  private var observers: [NSObjectProtocol] = []
  private weak var configuredWindow: NSWindow?
  private var deferredConfigurationTask: Task<Void, Never>?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateObservers()
    applyConfiguration()
  }

  internal func applyConfiguration() {
    guard let window else { return }
    CleanWindowConfigurator.configure(window)
    deferredConfigurationTask?.cancel()
    deferredConfigurationTask = Task { @MainActor [weak self, weak window] in
      await Task.yield()
      guard !Task.isCancelled, let self, let window, self.window === window else { return }
      CleanWindowConfigurator.configure(window)
    }
  }

  internal func waitForPendingConfiguration() async {
    await deferredConfigurationTask?.value
  }

  private func updateObservers() {
    guard configuredWindow !== window else { return }
    clearObservers()
    configuredWindow = window
    guard let window else { return }
    let center = NotificationCenter.default
    for name in [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.applyConfiguration()
          }
        }
      )
    }
  }

  private func clearObservers() {
    let center = NotificationCenter.default
    observers.forEach(center.removeObserver)
    observers.removeAll()
  }

  isolated deinit {
    deferredConfigurationTask?.cancel()
    clearObservers()
  }
}
