import ComposableArchitecture
import Foundation

struct TmuxAvailabilityClient: Sendable {
  var isAvailable: @Sendable () -> Bool
}

extension TmuxAvailabilityClient: DependencyKey {
  static let liveValue = TmuxAvailabilityClient(
    isAvailable: {
      TmuxTerminalController.resolveExecutable() != nil
    }
  )

  static let testValue = TmuxAvailabilityClient(
    isAvailable: { true }
  )
}

extension DependencyValues {
  var tmuxAvailabilityClient: TmuxAvailabilityClient {
    get { self[TmuxAvailabilityClient.self] }
    set { self[TmuxAvailabilityClient.self] = newValue }
  }
}
