import AppKit
import ComposableArchitecture

struct AppLifecycleClient: Sendable {
  var surfaceMainWindow: @MainActor @Sendable () -> Bool
  var terminate: @MainActor @Sendable () -> Void
}

extension AppLifecycleClient: DependencyKey {
  static let liveValue = AppLifecycleClient(
    surfaceMainWindow: {
      NSApplication.shared.surfaceMainWindow()
    },
    terminate: {
      NSApplication.shared.terminate(nil)
    }
  )

  static let testValue = AppLifecycleClient(
    surfaceMainWindow: { false },
    terminate: {}
  )
}

extension DependencyValues {
  var appLifecycleClient: AppLifecycleClient {
    get { self[AppLifecycleClient.self] }
    set { self[AppLifecycleClient.self] = newValue }
  }
}
