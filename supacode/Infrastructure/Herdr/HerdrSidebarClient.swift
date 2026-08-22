import ComposableArchitecture
import Darwin
import Foundation

nonisolated internal enum HerdrSidebarFailure: Error, Equatable, Sendable {
  case unavailable
  case connection(HerdrSocketError)
  case invalidResponse(String)
  case server(code: String, message: String)
  case incompatibleProtocol

  internal static func map(_ error: Error) -> Self {
    if let failure = error as? Self {
      return failure
    }
    guard let socketError = error as? HerdrSocketError else {
      return .invalidResponse(String(describing: error))
    }
    switch socketError {
    case .unsupportedProtocol, .unsupportedResponseType:
      return .incompatibleProtocol
    case .serverError(let code, let message):
      return .server(code: code, message: message)
    case .connectionFailed(ENOENT), .connectionFailed(ECONNREFUSED), .invalidSocketPath:
      return .unavailable
    case .invalidResponse:
      return .invalidResponse("The Herdr server returned an invalid response.")
    default:
      return .connection(socketError)
    }
  }
}

nonisolated internal struct HerdrSidebarClient: Sendable {
  internal var snapshot: @Sendable () async throws -> HerdrSidebarSnapshot
  internal var events: @Sendable () -> AsyncStream<HerdrEventStreamState>
  internal var focusWorkspace: @Sendable (String) async throws -> Void
  internal var focusTab: @Sendable (String) async throws -> Void
  internal var focusPane: @Sendable (String) async throws -> Void

  internal init(
    snapshot: @escaping @Sendable () async throws -> HerdrSidebarSnapshot,
    events: @escaping @Sendable () -> AsyncStream<HerdrEventStreamState>,
    focusWorkspace: @escaping @Sendable (String) async throws -> Void,
    focusTab: @escaping @Sendable (String) async throws -> Void,
    focusPane: @escaping @Sendable (String) async throws -> Void
  ) {
    self.snapshot = snapshot
    self.events = events
    self.focusWorkspace = focusWorkspace
    self.focusTab = focusTab
    self.focusPane = focusPane
  }
}

extension HerdrSidebarClient: DependencyKey {
  internal static let liveValue: Self = {
    let socketClient = HerdrSocketClient()
    return Self(
      snapshot: {
        try await socketClient.sessionSnapshot()
      },
      events: {
        socketClient.sidebarEvents()
      },
      focusWorkspace: { workspaceID in
        try await socketClient.focusWorkspace(workspaceID)
      },
      focusTab: { tabID in
        try await socketClient.focusTab(tabID)
      },
      focusPane: { paneID in
        try await socketClient.focusPane(paneID)
      }
    )
  }()

  internal static let testValue = Self(
    snapshot: { .empty },
    events: { AsyncStream { $0.finish() } },
    focusWorkspace: { _ in },
    focusTab: { _ in },
    focusPane: { _ in }
  )
}

extension DependencyValues {
  internal var herdrSidebarClient: HerdrSidebarClient {
    get { self[HerdrSidebarClient.self] }
    set { self[HerdrSidebarClient.self] = newValue }
  }
}
