import AppKit
import ComposableArchitecture
import Foundation
import UserNotifications

private nonisolated let notificationWorktreeIDKey = "prowl.worktreeID"
private nonisolated let notificationSurfaceIDKey = "prowl.surfaceID"

@MainActor
private final class ForegroundSystemNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  var onNotificationTap: ((Worktree.ID, UUID) -> Void)?

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await Task.yield()
    return [.badge, .sound, .banner]
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    await Task.yield()
    let userInfo = response.notification.request.content.userInfo
    guard let worktreeID = userInfo[notificationWorktreeIDKey] as? String,
      let rawSurfaceID = userInfo[notificationSurfaceIDKey] as? String,
      let surfaceID = UUID(uuidString: rawSurfaceID)
    else {
      return
    }
    onNotificationTap?(worktreeID, surfaceID)
  }
}

@MainActor
private let foregroundSystemNotificationDelegate = ForegroundSystemNotificationDelegate()

@MainActor
private func configuredNotificationCenter() -> UNUserNotificationCenter {
  let center = UNUserNotificationCenter.current()
  if center.delegate !== foregroundSystemNotificationDelegate {
    center.delegate = foregroundSystemNotificationDelegate
  }
  return center
}

@MainActor
func setSystemNotificationTapHandler(_ handler: @escaping @MainActor (Worktree.ID, UUID) -> Void) {
  _ = configuredNotificationCenter()
  foregroundSystemNotificationDelegate.onNotificationTap = handler
}

struct SystemNotificationClient {
  struct AuthorizationRequestResult: Equatable {
    let granted: Bool
    let errorMessage: String?
  }

  enum AuthorizationStatus: Equatable {
    case authorized
    case denied
    case notDetermined
  }

  /// Whether macOS will actually render the app's Dock badge. The Dock badge
  /// is gated by the system notification permission plus the per-app "Badge
  /// app icon" switch — it does not depend on Prowl's own banner toggle.
  enum DockBadgeAuthorization: Equatable {
    /// Notifications are allowed and "Badge app icon" is on.
    case available
    /// macOS is not allowing notifications for Prowl (denied or not yet asked).
    case notificationsDenied
    /// Notifications are allowed, but "Badge app icon" is turned off.
    case badgeDisabled
  }

  var authorizationStatus: @MainActor @Sendable () async -> AuthorizationStatus
  var dockBadgeAuthorization: @MainActor @Sendable () async -> DockBadgeAuthorization
  var requestAuthorization: @MainActor @Sendable () async -> AuthorizationRequestResult
  var send:
    @MainActor @Sendable (_ title: String, _ body: String, _ worktreeID: Worktree.ID?, _ surfaceID: UUID?) async -> Void
  var openSettings: @MainActor @Sendable () async -> Void
}

extension SystemNotificationClient: DependencyKey {
  static let liveValue = SystemNotificationClient(
    authorizationStatus: {
      let center = configuredNotificationCenter()
      let settings = await center.notificationSettings()
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        return .authorized
      case .denied:
        return .denied
      case .notDetermined:
        return .notDetermined
      @unknown default:
        return .denied
      }
    },
    dockBadgeAuthorization: {
      let center = configuredNotificationCenter()
      let settings = await center.notificationSettings()
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        return settings.badgeSetting == .enabled ? .available : .badgeDisabled
      default:
        return .notificationsDenied
      }
    },
    requestAuthorization: {
      let center = configuredNotificationCenter()
      do {
        let granted = try await center.requestAuthorization(
          options: [.alert, .badge, .sound]
        )
        return AuthorizationRequestResult(granted: granted, errorMessage: nil)
      } catch {
        return AuthorizationRequestResult(
          granted: false,
          errorMessage: error.localizedDescription
        )
      }
    },
    send: { title, body, worktreeID, surfaceID in
      let center = configuredNotificationCenter()
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      if let worktreeID, let surfaceID {
        content.userInfo = [
          notificationWorktreeIDKey: worktreeID,
          notificationSurfaceIDKey: surfaceID.uuidString,
        ]
      }
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      try? await center.add(request)
    },
    openSettings: {
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
        return
      }
      _ = NSWorkspace.shared.open(url)
    }
  )

  static let testValue = SystemNotificationClient(
    authorizationStatus: { .notDetermined },
    dockBadgeAuthorization: { .available },
    requestAuthorization: { AuthorizationRequestResult(granted: false, errorMessage: nil) },
    send: { _, _, _, _ in },
    openSettings: {}
  )
}

extension DependencyValues {
  var systemNotificationClient: SystemNotificationClient {
    get { self[SystemNotificationClient.self] }
    set { self[SystemNotificationClient.self] = newValue }
  }
}
