import ComposableArchitecture
import Foundation

/// Connects the HUD reducer to the app-owned request registry that authorizes
/// injected CLI transitions.
struct HandoffRequestClient: Sendable {
  var register: @MainActor @Sendable (UUID, HandoffRequestExpectation) -> Void
  var supersede: @MainActor @Sendable (UUID) -> Bool
}

extension HandoffRequestClient: DependencyKey {
  static let liveValue = Self(
    register: { _, _ in },
    supersede: { _ in true }
  )

  static let testValue = Self(
    register: { _, _ in },
    supersede: { _ in true }
  )
}

extension DependencyValues {
  var handoffRequestClient: HandoffRequestClient {
    get { self[HandoffRequestClient.self] }
    set { self[HandoffRequestClient.self] = newValue }
  }
}
