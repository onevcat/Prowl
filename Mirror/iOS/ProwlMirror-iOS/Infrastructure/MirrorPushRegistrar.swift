import CryptoKit
import Foundation
import UIKit
import UserNotifications
import os

/// APNs registration of this phone (docs-ai 095). iOS hands the device token only to the app
/// delegate, which forwards it here.
final class MirrorPushRegistrar {
  static let shared = MirrorPushRegistrar()

  private(set) var apnsToken: String?
  private var waiters: [CheckedContinuation<String?, Never>] = []

  /// Asks for permission to alert, then for an APNs token (lowercase hex). `nil` when the user
  /// refuses or registration fails.
  func register() async -> String? {
    let center = UNUserNotificationCenter.current()
    guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return nil }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  func didRegister(deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    apnsToken = token
    finish(token)
  }

  func didFailToRegister() {
    finish(nil)
  }

  private func finish(_ token: String?) {
    let waiting = waiters
    waiters.removeAll()
    waiting.forEach { $0.resume(returning: token) }
  }
}

final class MirrorAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    #if DEBUG
      Self.applyPushDebugKey()
    #endif
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    MirrorPushRegistrar.shared.didRegister(deviceToken: deviceToken)
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    MirrorLog.push.error("APNs registration failed: \(String(describing: error), privacy: .private)")
    MirrorPushRegistrar.shared.didFailToRegister()
  }

  #if DEBUG
    /// Device checks before the Host sends pushes: `MIRROR_PUSH_DEBUG_KEY=<Host UUID>:<64 hex>`
    /// saves that push key and registers for APNs, and the token goes to stdout;
    /// `MIRROR_PUSH_DEBUG_DELIVERED=1` prints the delivered notifications as shown;
    /// `MIRROR_PUSH_DEBUG_GATEWAY=1` also attests and asks the gateway for a push token;
    /// `MIRROR_PUSH_DEBUG_ENABLE=1|0` turns notifications on or off until settings exist (P3e).
    private static func applyPushDebugKey() {
      if let value = ProcessInfo.processInfo.environment["MIRROR_PUSH_DEBUG_ENABLE"] {
        UserDefaults.standard.set(value == "1", forKey: MirrorPushCoordinator.enabledKey)
      }
      if ProcessInfo.processInfo.environment["MIRROR_PUSH_DEBUG_GATEWAY"] == "1" {
        Task {
          guard let apnsToken = await MirrorPushRegistrar.shared.register() else {
            return print("MIRROR_PUSH_DEBUG gateway: no APNs token")
          }
          do {
            let environment = MirrorAPNsEnvironment.current
            let pushToken = try await MirrorPushGatewayClient().createToken(
              apnsToken: apnsToken, environment: environment)
            print("MIRROR_PUSH_DEBUG gateway environment=\(environment.rawValue) pushToken=\(pushToken)")
          } catch {
            print("MIRROR_PUSH_DEBUG gateway failed: \(error)")
          }
        }
      }
      if ProcessInfo.processInfo.environment["MIRROR_PUSH_DEBUG_DELIVERED"] == "1" {
        Task {
          for note in await UNUserNotificationCenter.current().deliveredNotifications() {
            let content = note.request.content
            print("MIRROR_PUSH_DEBUG delivered title=\(content.title) body=\(content.body) info=\(content.userInfo)")
          }
        }
      }
      guard let value = ProcessInfo.processInfo.environment["MIRROR_PUSH_DEBUG_KEY"] else { return }
      let parts = value.split(separator: ":")
      guard parts.count == 2, let hostID = UUID(uuidString: String(parts[0])),
        let bytes = Data(hex: String(parts[1])), bytes.count == 32
      else { return print("MIRROR_PUSH_DEBUG invalid key") }
      do {
        try MirrorPushKeyStore.save(SymmetricKey(data: bytes), hostID: hostID)
      } catch {
        return print("MIRROR_PUSH_DEBUG save failed: \(error)")
      }
      Task { print("MIRROR_PUSH_DEBUG apnsToken=\(await MirrorPushRegistrar.shared.register() ?? "none")") }
    }
  #endif
}

#if DEBUG
  extension Data {
    fileprivate init?(hex: String) {
      guard hex.count.isMultiple(of: 2) else { return nil }
      var bytes: [UInt8] = []
      var index = hex.startIndex
      while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
      }
      self.init(bytes)
    }
  }
#endif
