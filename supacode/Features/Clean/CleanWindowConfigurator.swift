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
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    window.isMovableByWindowBackground = false
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    // Tahoe still draws the titlebar backdrop above full-size content unless the container is hidden.
    if !window.styleMask.contains(.fullScreen) {
      titlebarContainer(in: window)?.isHidden = true
    }
  }

  internal static func titlebarContainer(in window: NSWindow) -> NSView? {
    window.contentView?.superview?.firstDescendant(named: "NSTitlebarContainerView")
  }
}

extension NSView {
  fileprivate func firstDescendant(named className: String) -> NSView? {
    for subview in subviews {
      if String(describing: type(of: subview)) == className {
        return subview
      }
      if let match = subview.firstDescendant(named: className) {
        return match
      }
    }
    return nil
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
