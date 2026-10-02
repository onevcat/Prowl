import AppKit
import Foundation
import Sentry

enum WindowID {
  static let main = "main"
  static let settings = "settings"
}

extension NSApplication {
  @MainActor
  @discardableResult
  func surfaceMainWindow() -> Bool {
    guard let window = mainWindowCandidate() else {
      // SwiftUI tore down (or never created) the singleton main Window scene.
      // A bare activate() cannot bring it back; only openWindow(id:) rebuilds
      // it. See MainWindowOpener / issue #297.
      if MainWindowOpener.shared.hasRegisteredOpener {
        WindowLifecycleDiagnostics.noteWindowless("surfaceMainWindow(openWindowRequested)")
      }
      if MainWindowOpener.shared.openMainWindow() {
        WindowLifecycleDiagnostics.log("surfaceMainWindow: no candidate -> openWindow(id:.main) requested")
        activate(ignoringOtherApps: true)
        return true
      }
      WindowLifecycleDiagnostics.log("surfaceMainWindow: no candidate and opener unavailable -> activate only")
      WindowLifecycleDiagnostics.noteWindowless("surfaceMainWindow(noOpener)")
      activate(ignoringOtherApps: true)
      return false
    }
    WindowLifecycleDiagnostics.log(
      "surfaceMainWindow: candidate id=\(window.identifier?.rawValue ?? "nil") "
        + "miniaturized=\(window.isMiniaturized) visible=\(window.isVisible) -> makeKeyAndOrderFront"
    )
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    WindowLifecycleDiagnostics.noteMainWindowAppeared()
    return true
  }

  private func mainWindowCandidate() -> NSWindow? {
    MainWindowSurface.mainWindowCandidate(in: windows)
  }
}

// MARK: - Issue #297 diagnostics

enum MainWindowSurface {
  struct Snapshot: Equatable {
    let identifier: String?
    let isVisible: Bool
  }

  static func snapshots(in windows: [NSWindow]) -> [Snapshot] {
    windows.map(snapshot(for:))
  }

  static func mainWindowCandidate(in windows: [NSWindow]) -> NSWindow? {
    let snapshots = snapshots(in: windows)
    guard let index = mainWindowIndex(in: snapshots) else { return nil }
    return windows[index]
  }

  static func hasVisibleMainWindow(in windows: [NSWindow]) -> Bool {
    hasVisibleMainWindow(in: snapshots(in: windows))
  }

  static func mainWindowCount(in windows: [NSWindow]) -> Int {
    mainWindowCount(in: snapshots(in: windows))
  }

  static func visibleMainWindowCount(in windows: [NSWindow]) -> Int {
    visibleMainWindowCount(in: snapshots(in: windows))
  }

  static func visibleWindowCount(in windows: [NSWindow]) -> Int {
    visibleWindowCount(in: snapshots(in: windows))
  }

  static func mainWindowIndex(in snapshots: [Snapshot]) -> Int? {
    snapshots.firstIndex(where: isMainWindow)
  }

  static func hasVisibleMainWindow(in snapshots: [Snapshot]) -> Bool {
    snapshots.contains { isMainWindow($0) && $0.isVisible }
  }

  static func mainWindowCount(in snapshots: [Snapshot]) -> Int {
    snapshots.count(where: isMainWindow)
  }

  static func visibleMainWindowCount(in snapshots: [Snapshot]) -> Int {
    snapshots.count(where: { isMainWindow($0) && $0.isVisible })
  }

  static func visibleWindowCount(in snapshots: [Snapshot]) -> Int {
    snapshots.count(where: \.isVisible)
  }

  private static func snapshot(for window: NSWindow) -> Snapshot {
    Snapshot(identifier: window.identifier?.rawValue, isVisible: window.isVisible)
  }

  private static func isMainWindow(_ snapshot: Snapshot) -> Bool {
    snapshot.identifier == WindowID.main
  }
}

@MainActor
enum WindowLifecycleDiagnostics {
  enum WindowlessReportDecision: Equatable {
    case report
    case suppress
    case resolveVisibleMainWindow
  }

  private static let logger = SupaLogger("WindowLifecycle")
  private static let heartbeatInterval: TimeInterval = 1.0
  private static let stallThreshold: TimeInterval = 0.3
  private static let windowlessReminderInterval: TimeInterval = 5.0
  private static let windowlessSentryThreshold: TimeInterval = 10.0
  private static let windowlessStallSentryThreshold: TimeInterval = 5.0

  private static var windowlessSince: Date?
  private static var windowlessContext: String?
  private static var windowlessReminderScheduled = false
  private static var didReportWindowlessTimeout = false
  private static var didReportWindowlessStall = false
  private static var maxHeartbeatLagDuringWindowless: TimeInterval = 0
  private static var heartbeatRunning = false
  private static var mainThreadStalling = false

  static func log(_ event: String) {
    logger.info(event)
  }

  static func logWithWindows(_ event: String) {
    log("\(event) | \(windowsSummary())")
  }

  static func noteWindowless(_ context: String) {
    if windowlessSince == nil {
      windowlessSince = .now
      windowlessContext = context
      didReportWindowlessTimeout = false
      didReportWindowlessStall = false
      maxHeartbeatLagDuringWindowless = 0
      log("windowless ENTERED (\(context))")
    } else {
      windowlessContext = context
    }
    scheduleWindowlessReminder()
  }

  /// Marks the app as windowless when there is no *visible* `WindowID.main` window.
  static func noteWindowlessIfNoMainWindow(_ context: String) {
    guard !MainWindowSurface.hasVisibleMainWindow(in: NSApplication.shared.windows) else {
      noteMainWindowAppeared()
      return
    }
    noteWindowless(context)
  }

  static func noteMainWindowAppeared() {
    guard let since = windowlessSince else { return }
    let seconds = Date.now.timeIntervalSince(since)
    log(String(format: "windowless RESOLVED: main window appeared after %.3fs", seconds))
    windowlessSince = nil
    windowlessContext = nil
  }

  private static func scheduleWindowlessReminder() {
    guard !windowlessReminderScheduled else { return }
    windowlessReminderScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + windowlessReminderInterval) {
      MainActor.assumeIsolated {
        windowlessReminderScheduled = false
        guard let since = windowlessSince else { return }
        guard !MainWindowSurface.hasVisibleMainWindow(in: NSApplication.shared.windows) else {
          noteMainWindowAppeared()
          return
        }
        let seconds = Date.now.timeIntervalSince(since)
        log(
          String(
            format: "still windowless after %.1fs (context=%@, maxLag=%.3fs)",
            seconds,
            windowlessContext ?? "unknown",
            maxHeartbeatLagDuringWindowless
          )
        )
        if seconds >= windowlessSentryThreshold {
          reportWindowlessTimeoutIfNeeded(elapsed: seconds)
        }
        scheduleWindowlessReminder()
      }
    }
  }

  static func startMainThreadHeartbeat() {
    guard !heartbeatRunning else { return }
    heartbeatRunning = true
    log("main-thread heartbeat started (interval=\(heartbeatInterval)s, stallThreshold=\(stallThreshold)s)")
    scheduleHeartbeatTick()
  }

  private static func scheduleHeartbeatTick() {
    let scheduledAt = Date.now
    DispatchQueue.main.asyncAfter(deadline: .now() + heartbeatInterval) {
      MainActor.assumeIsolated {
        let lag = Date.now.timeIntervalSince(scheduledAt) - heartbeatInterval
        if lag >= stallThreshold {
          mainThreadStalling = true
          if windowlessSince != nil {
            maxHeartbeatLagDuringWindowless = max(maxHeartbeatLagDuringWindowless, lag)
            if lag >= windowlessStallSentryThreshold {
              reportWindowlessStallIfNeeded(lag: lag)
            }
          }
          log(String(format: "HEARTBEAT STALL: main thread blocked ~%.3fs", lag))
        } else if mainThreadStalling {
          mainThreadStalling = false
          log(String(format: "heartbeat recovered (lag back to %.3fs)", lag))
        }
        scheduleHeartbeatTick()
      }
    }
  }

  static func applyLaunchStallIfConfigured() {
    let seconds = UserDefaults.standard.double(forKey: "ProwlDebugLaunchStallSeconds")
    guard seconds > 0 else { return }
    log("DEBUG launch stall: blocking main thread for \(seconds)s (ProwlDebugLaunchStallSeconds)")
    Thread.sleep(forTimeInterval: seconds)
    log("DEBUG launch stall: resumed")
  }

  private static func reportWindowlessTimeoutIfNeeded(elapsed: TimeInterval) {
    guard !didReportWindowlessTimeout else { return }
    let windows = NSApplication.shared.windows
    switch Self.windowlessTimeoutReportDecision(
      appIsActive: NSApp.isActive,
      windowlessContext: windowlessContext,
      snapshots: MainWindowSurface.snapshots(in: windows)
    ) {
    case .report:
      break
    case .suppress:
      return
    case .resolveVisibleMainWindow:
      noteMainWindowAppeared()
      return
    }
    didReportWindowlessTimeout = true
    captureSentryEvent(kind: "main_window_timeout", elapsed: elapsed, lag: nil)
  }

  private static func reportWindowlessStallIfNeeded(lag: TimeInterval) {
    guard !didReportWindowlessStall else { return }
    let windows = NSApplication.shared.windows
    switch Self.windowlessStallReportDecision(
      appIsActive: NSApp.isActive,
      snapshots: MainWindowSurface.snapshots(in: windows)
    ) {
    case .report:
      break
    case .suppress:
      return
    case .resolveVisibleMainWindow:
      noteMainWindowAppeared()
      return
    }
    didReportWindowlessStall = true
    let elapsed = windowlessSince.map { Date.now.timeIntervalSince($0) } ?? 0
    captureSentryEvent(kind: "windowless_main_thread_stall", elapsed: elapsed, lag: lag)
  }

  static func windowlessStallReportDecision(
    appIsActive: Bool,
    snapshots: [MainWindowSurface.Snapshot]
  ) -> WindowlessReportDecision {
    if MainWindowSurface.hasVisibleMainWindow(in: snapshots) {
      return .resolveVisibleMainWindow
    }
    guard appIsActive else { return .suppress }
    return .report
  }

  static func windowlessTimeoutReportDecision(
    appIsActive: Bool,
    windowlessContext: String?,
    snapshots: [MainWindowSurface.Snapshot]
  ) -> WindowlessReportDecision {
    if MainWindowSurface.hasVisibleMainWindow(in: snapshots) {
      return .resolveVisibleMainWindow
    }
    guard windowlessContext != "launch" || appIsActive else {
      return .suppress
    }
    return .report
  }

  private static func captureSentryEvent(kind: String, elapsed: TimeInterval, lag: TimeInterval?) {
    let context = windowlessContext ?? "unknown"
    log(
      String(
        format: "Sentry window lifecycle report kind=%@ elapsed=%.3fs context=%@",
        kind,
        elapsed,
        context
      )
    )

    #if !DEBUG
      let event = Event(level: .warning)
      event.message = SentryMessage(formatted: "Prowl main window surfacing \(kind)")
      event.logger = "WindowLifecycle"
      event.fingerprint = ["prowl", "main-window-surfacing", kind]
      let windows = NSApplication.shared.windows
      let mainWindowCount = MainWindowSurface.mainWindowCount(in: windows)
      let visibleMainWindowCount = MainWindowSurface.visibleMainWindowCount(in: windows)
      let visibleWindowCount = MainWindowSurface.visibleWindowCount(in: windows)
      event.tags = [
        "window_lifecycle_kind": kind,
        "windowless_context": context,
        "app_active": NSApp.isActive ? "true" : "false",
        "main_window_opener_registered": MainWindowOpener.shared.hasRegisteredOpener ? "true" : "false",
        "has_visible_main_window": visibleMainWindowCount > 0 ? "true" : "false",
        "main_window_count": "\(mainWindowCount)",
        "visible_main_window_count": "\(visibleMainWindowCount)",
        "visible_window_count": "\(visibleWindowCount)",
      ]
      var extra: [String: Any] = [
        "elapsed_seconds": elapsed,
        "windowless_context": context,
        "windows": windowsSummary(windows),
        "main_window_count": mainWindowCount,
        "visible_main_window_count": visibleMainWindowCount,
        "visible_window_count": visibleWindowCount,
        "max_heartbeat_lag_seconds": maxHeartbeatLagDuringWindowless,
        "arguments": ProcessInfo.processInfo.arguments.joined(separator: " "),
      ]
      if let lag {
        extra["heartbeat_lag_seconds"] = lag
      }
      event.extra = extra
      SentrySDK.capture(event: event)
    #endif
  }

  private static func windowsSummary() -> String {
    windowsSummary(NSApplication.shared.windows)
  }

  private static func windowsSummary(_ windows: [NSWindow]) -> String {
    guard !windows.isEmpty else { return "windows[0]=(none)" }
    let parts = windows.map { window -> String in
      let id = window.identifier?.rawValue ?? "nil"
      let type = String(describing: Swift.type(of: window))
      let visibility = window.isVisible ? "visible" : "hidden"
      let miniaturized = window.isMiniaturized ? ",mini" : ""
      let key = window.isKeyWindow ? ",key" : ""
      return "{id=\(id),\(type),\(visibility)\(miniaturized)\(key)}"
    }
    return "windows[\(windows.count)]=\(parts.joined(separator: " "))"
  }
}
