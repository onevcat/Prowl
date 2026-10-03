import AppKit
import ComposableArchitecture

/// Side effects targeting the app's Dock tile: the pending-notification badge
/// and the attention bounce. Wrapping these in a dependency keeps the reducer
/// testable and matches how the other AppKit side effects are injected.
struct DockClient {
  /// Set the Dock tile's notification badge to `count` unread items, or clear
  /// it when `count` is zero.
  var setNotificationBadge: @MainActor @Sendable (_ count: Int) -> Void
  /// Bounce the Dock icon according to the configured mode. `.off` is a no-op.
  var bounce: @MainActor @Sendable (_ mode: DockBounceMode) -> Void
}

extension DockClient: DependencyKey {
  static let liveValue = DockClient(
    setNotificationBadge: { count in
      let dockTile = NSApplication.shared.dockTile
      dockTile.badgeLabel = count > 0 ? String(count) : nil
      // Setting `badgeLabel` alone doesn't always repaint the tile; force a
      // redraw so the badge actually appears/clears.
      dockTile.display()
    },
    bounce: { mode in
      switch mode {
      case .off:
        break
      case .once:
        _ = NSApp.requestUserAttention(.informationalRequest)
      case .continuous:
        _ = NSApp.requestUserAttention(.criticalRequest)
      }
    }
  )

  static let testValue = DockClient(
    setNotificationBadge: { _ in },
    bounce: { _ in }
  )
}

extension DependencyValues {
  var dockClient: DockClient {
    get { self[DockClient.self] }
    set { self[DockClient.self] = newValue }
  }
}
