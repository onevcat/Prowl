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
    titlebarContainer(in: window)?.isHidden = true
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

@MainActor
internal final class CleanTitlebarMouseForwarder {
  internal typealias EventHandler = @MainActor (NSEvent) -> Void

  private static let eventMask: NSEvent.EventTypeMask = [
    .leftMouseDown,
    .leftMouseUp,
    .leftMouseDragged,
    .mouseMoved,
    .scrollWheel,
  ]

  private weak var surfaceView: NSView?
  private let eventHandler: EventHandler
  private var eventMonitor: Any?
  private var isForwardingLeftMouseGesture = false

  internal init(
    surfaceView: NSView,
    eventHandler: @escaping EventHandler
  ) {
    self.surfaceView = surfaceView
    self.eventHandler = eventHandler
  }

  isolated deinit {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
  }

  internal func start() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
      self?.route(event) ?? event
    }
  }

  internal func stop() {
    isForwardingLeftMouseGesture = false
    guard let eventMonitor else { return }
    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }

  internal func route(_ event: NSEvent) -> NSEvent? {
    guard let surfaceView, let window = surfaceView.window, event.window === window else {
      if event.type == .leftMouseDown || event.type == .leftMouseUp {
        isForwardingLeftMouseGesture = false
      }
      return event
    }

    switch event.type {
    case .leftMouseDown:
      isForwardingLeftMouseGesture = false
      guard shouldForwardNewEvent(event, to: surfaceView, in: window) else { return event }
      isForwardingLeftMouseGesture = true
    case .leftMouseDragged, .leftMouseUp:
      guard isForwardingLeftMouseGesture else { return event }
      if event.type == .leftMouseUp {
        isForwardingLeftMouseGesture = false
      }
    case .mouseMoved, .scrollWheel:
      guard shouldForwardNewEvent(event, to: surfaceView, in: window) else { return event }
    default:
      return event
    }

    eventHandler(event)
    return nil
  }

  private func shouldForwardNewEvent(
    _ event: NSEvent,
    to surfaceView: NSView,
    in window: NSWindow
  ) -> Bool {
    guard !nativeControlHit(at: event.locationInWindow, in: window) else { return false }
    let surfacePoint = surfaceView.convert(event.locationInWindow, from: nil)
    return surfaceView.bounds.contains(surfacePoint)
      && !window.contentLayoutRect.contains(event.locationInWindow)
  }

  private func nativeControlHit(at point: NSPoint, in window: NSWindow) -> Bool {
    guard let contentView = window.contentView else { return false }
    let contentPoint = contentView.convert(point, from: nil)
    var hitView = contentView.hitTest(contentPoint)
    while let view = hitView {
      if view is NSControl { return true }
      hitView = view.superview
    }
    return false
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
