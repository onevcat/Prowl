import ComposableArchitecture
import Darwin
import Foundation

nonisolated internal enum HerdrTerminalChromeFailure: Error, Equatable, Sendable {
  case unavailable
  case connection(HerdrSocketError)
  case invalidResponse(String)
  case server(code: String, message: String)
  case incompatibleProtocol(HerdrSocketError)

  internal static func map(_ error: Error) -> Self {
    if let failure = error as? Self {
      return failure
    }
    guard let socketError = error as? HerdrSocketError else {
      return .invalidResponse(String(describing: error))
    }
    switch socketError {
    case .unsupportedProtocol, .unsupportedResponseType:
      return .incompatibleProtocol(socketError)
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

  internal var isIncompatibleProtocol: Bool {
    if case .incompatibleProtocol = self {
      return true
    }
    return false
  }

  internal var isNotFound: Bool {
    if case .server(let code, _) = self {
      return code == "not_found"
    }
    return false
  }

  internal var isConfirmationRequired: Bool {
    if case .server(let code, _) = self {
      return code == "confirmation_required"
    }
    return false
  }
}

nonisolated internal struct HerdrEventSubscription: Sendable {
  internal let stream: AsyncStream<HerdrEventStreamState>
  internal let cancel: @Sendable () -> Void

  internal init(
    stream: AsyncStream<HerdrEventStreamState>,
    cancel: @escaping @Sendable () -> Void
  ) {
    self.stream = stream
    self.cancel = cancel
  }
}

nonisolated internal struct HerdrTerminalChromeClient: Sendable {
  internal var snapshot: @Sendable () async throws -> HerdrSessionSnapshot
  internal var subscribeEvents: @Sendable (Set<String>) async throws -> HerdrEventSubscription
  internal var focusWorkspace: @Sendable (String) async throws -> Void
  internal var focusTab: @Sendable (String) async throws -> Void
  internal var focusPane: @Sendable (String) async throws -> Void
  internal var createWorkspace: @Sendable () async throws -> Void
  internal var createTab: @Sendable (String, String?, String?) async throws -> Void
  internal var renameTab: @Sendable (String, String?) async throws -> Void
  internal var moveTab: @Sendable (String, Int) async throws -> Void
  internal var closeTab: @Sendable (String) async throws -> Void
  internal var closeWorkspace: @Sendable (String) async throws -> Void

  internal init(
    snapshot: @escaping @Sendable () async throws -> HerdrSessionSnapshot,
    subscribeEvents: @escaping @Sendable (Set<String>) async throws -> HerdrEventSubscription,
    focusWorkspace: @escaping @Sendable (String) async throws -> Void,
    focusTab: @escaping @Sendable (String) async throws -> Void,
    focusPane: @escaping @Sendable (String) async throws -> Void,
    createWorkspace: @escaping @Sendable () async throws -> Void = {},
    createTab: @escaping @Sendable (String, String?, String?) async throws -> Void,
    renameTab: @escaping @Sendable (String, String?) async throws -> Void,
    moveTab: @escaping @Sendable (String, Int) async throws -> Void,
    closeTab: @escaping @Sendable (String) async throws -> Void,
    closeWorkspace: @escaping @Sendable (String) async throws -> Void
  ) {
    self.snapshot = snapshot
    self.subscribeEvents = subscribeEvents
    self.focusWorkspace = focusWorkspace
    self.focusTab = focusTab
    self.focusPane = focusPane
    self.createWorkspace = createWorkspace
    self.createTab = createTab
    self.renameTab = renameTab
    self.moveTab = moveTab
    self.closeTab = closeTab
    self.closeWorkspace = closeWorkspace
  }
}

extension HerdrTerminalChromeClient: DependencyKey {
  internal static let liveValue: Self = {
    let socketClient = HerdrSocketClient()
    return Self(
      snapshot: {
        try await socketClient.sessionSnapshot()
      },
      subscribeEvents: { paneIDs in
        try await socketClient.terminalChromeEventSubscription(paneIDs: paneIDs)
      },
      focusWorkspace: { workspaceID in
        try await socketClient.focusWorkspace(workspaceID)
      },
      focusTab: { tabID in
        try await socketClient.focusTab(tabID)
      },
      focusPane: { paneID in
        try await socketClient.focusPane(paneID)
      },
      createWorkspace: {
        try await socketClient.createWorkspace()
      },
      createTab: { workspaceID, label, sourceTabID in
        try await socketClient.createTab(
          workspaceID: workspaceID,
          label: label,
          sourceTabID: sourceTabID
        )
      },
      renameTab: { tabID, label in
        try await socketClient.renameTab(tabID: tabID, label: label)
      },
      moveTab: { tabID, insertIndex in
        try await socketClient.moveTab(tabID: tabID, insertIndex: insertIndex)
      },
      closeTab: { tabID in
        try await socketClient.closeTab(tabID: tabID)
      },
      closeWorkspace: { workspaceID in
        try await socketClient.closeWorkspace(workspaceID: workspaceID)
      }
    )
  }()

  internal static let testValue = Self(
    snapshot: { .empty },
    subscribeEvents: { _ in
      HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
    },
    focusWorkspace: { _ in },
    focusTab: { _ in },
    focusPane: { _ in },
    createWorkspace: {},
    createTab: { _, _, _ in },
    renameTab: { _, _ in },
    moveTab: { _, _ in },
    closeTab: { _ in },
    closeWorkspace: { _ in }
  )
}

extension DependencyValues {
  internal var herdrTerminalChromeClient: HerdrTerminalChromeClient {
    get { self[HerdrTerminalChromeClient.self] }
    set { self[HerdrTerminalChromeClient.self] = newValue }
  }
}
