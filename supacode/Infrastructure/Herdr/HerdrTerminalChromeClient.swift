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

nonisolated private final class HerdrNativeContractSessionBox: @unchecked Sendable {
  private let lock = NSLock()
  private var session: HerdrNativeContractSession?

  internal func set(_ session: HerdrNativeContractSession?) {
    lock.withLock { self.session = session }
  }

  internal func send(_ request: HerdrNativeActionRequest) async throws {
    let session = lock.withLock { self.session }
    guard let session else { throw HerdrNativeChromeTransportError.notConnected }
    let envelope = HerdrNativeChromeEnvelope(
      contractVersion: HerdrNativeChromeRendezvous.contractVersion,
      clientInstanceID: session.clientInstanceID,
      messageKind: "action",
      eventSequence: nil,
      projectionRevision: nil,
      requestID: request.requestID,
      activationEpoch: request.activationEpoch,
      payload: request.payload
    )
    try await session.send(JSONEncoder().encode(envelope))
  }
}

nonisolated internal struct HerdrTerminalChromeClient: Sendable {
  internal var nativeEvents: @Sendable () -> AsyncStream<HerdrNativeClientEvent>
  internal var sendNativeAction: @Sendable (HerdrNativeActionRequest) async throws -> Void
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
    nativeEvents: @escaping @Sendable () -> AsyncStream<HerdrNativeClientEvent> = {
      AsyncStream {
        $0.yield(.noContractClaim)
        $0.finish()
      }
    },
    sendNativeAction: @escaping @Sendable (HerdrNativeActionRequest) async throws -> Void = { _ in
    },
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
    self.nativeEvents = nativeEvents
    self.sendNativeAction = sendNativeAction
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
  internal static func live(coordinator: HerdrNativeChromeCoordinator) -> Self {
    let socketClient = HerdrSocketClient()
    let sessionBox = HerdrNativeContractSessionBox()
    return Self(
      nativeEvents: {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
          let task = Task {
            switch await coordinator.probe() {
            case .noContractClaim:
              continuation.yield(.noContractClaim)
              continuation.finish()
            case .incompatible(let message):
              continuation.yield(.incompatible(message))
              continuation.finish()
            case .aggregate(let session):
              sessionBox.set(session)
              continuation.yield(.aggregateStarted(clientInstanceID: session.clientInstanceID))
              for await state in session.stream {
                guard !Task.isCancelled else { break }
                continuation.yield(.stream(state))
              }
              sessionBox.set(nil)
              continuation.finish()
            }
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      },
      sendNativeAction: { request in
        try await sessionBox.send(request)
      },
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
  }

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
