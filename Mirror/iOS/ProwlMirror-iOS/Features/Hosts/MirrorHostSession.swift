import Foundation
import Observation

/// One connection to a Host for what is not a pane: pairing, the pane roster, launching.
/// A pane that is opened gets its own `MirrorSession`; this one keeps listing (docs-ai 088).
@MainActor
@Observable
final class MirrorHostSession {
  enum Status: Equatable {
    case idle
    case connecting
    case ready
    case failed(String)

    var label: String {
      switch self {
      case .idle: String(localized: "Not connected")
      case .connecting: String(localized: "Connecting…")
      case .ready: String(localized: "Connected")
      case .failed(let reason): reason
      }
    }
  }

  private(set) var configuration: MirrorSavedConnection
  private(set) var status: Status = .idle
  private(set) var panes: [MirrorPaneDescriptor] = []
  private(set) var capabilities: Set<String> = []
  private(set) var hostRunID: UUID?
  private(set) var lastRefreshedAt: Date?
  /// Called once the Host verified the device; carries the credential-bearing configuration.
  var onVerified: ((MirrorSavedConnection) -> Void)?

  var supportsConversation: Bool { capabilities.contains("conversation-v1") }
  var supportsLaunch: Bool { capabilities.contains("launch-profile") }
  var supportsShellLaunch: Bool { capabilities.contains("launch-shell") }

  @ObservationIgnored private var transport: (any MirrorTransport)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var pendingCommands: [UUID: PendingCommand] = [:]
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let refreshInterval: Duration
  @ObservationIgnored private let makeTransport: (MirrorSavedConnection) throws -> any MirrorTransport

  private struct PendingCommand {
    let continuation: CheckedContinuation<MirrorJSON, any Error>
    let timeout: Task<Void, Never>
  }

  enum CommandFailure: LocalizedError {
    case unavailable, disconnected, timedOut
    var errorDescription: String? {
      switch self {
      case .unavailable: String(localized: "The Host is not connected or another command is pending.")
      case .disconnected: String(localized: "Connection lost before the Host confirmed the command.")
      case .timedOut: String(localized: "The Host did not confirm the command in time.")
      }
    }
  }

  init(
    configuration: MirrorSavedConnection,
    clock: any Clock<Duration> = ContinuousClock(),
    refreshInterval: Duration = .seconds(3),
    makeTransport: @escaping (MirrorSavedConnection) throws -> any MirrorTransport = {
      MirrorRemoteConnection(configuration: $0)
    }
  ) {
    self.configuration = configuration
    self.clock = clock
    self.refreshInterval = refreshInterval
    self.makeTransport = makeTransport
  }

  func start() {
    guard transport == nil else { return }
    status = .connecting
    generation = UUID()
    let attempt = generation
    do {
      let channel = try makeTransport(configuration)
      transport = channel
      channel.onEnrolled = { [weak self] enrolled in
        guard let self, self.generation == attempt else { return }
        self.configuration = enrolled
      }
      channel.onReady = { [weak self] in
        guard let self, self.generation == attempt else { return }
        if let verified = self.transport?.verifiedConfiguration { self.configuration = verified }
        self.onVerified?(self.configuration)
        self.send(.list)
        self.scheduleRefresh()
      }
      channel.onMessage = { [weak self] message in
        guard let self, self.generation == attempt else { return }
        self.receive(message)
      }
      channel.onClose = { [weak self] reason in
        guard let self, self.generation == attempt else { return }
        self.transport = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.failPendingCommands(CommandFailure.disconnected)
        self.status = .failed(reason ?? String(localized: "Connection lost."))
      }
      channel.start()
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    generation = UUID()
    refreshTask?.cancel()
    refreshTask = nil
    failPendingCommands(CommandFailure.disconnected)
    let old = transport
    transport = nil
    old?.onClose = nil
    old?.close(nil)
    if status != .idle { status = .idle }
  }

  func retry() {
    stop()
    start()
  }

  func refresh() {
    guard status == .ready else { return }
    send(.list)
  }

  /// Runs one Host command; several may be in flight, each correlated by its request ID.
  func command(_ command: MirrorCommandRequest.Command) async throws -> MirrorJSON {
    guard status == .ready, transport != nil else { throw CommandFailure.unavailable }
    let request = MirrorCommandRequest(requestID: UUID(), request: .init(command: command))
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let clock = clock
        let timeout = Task { [weak self] in
          do { try await clock.sleep(for: .seconds(30)) } catch { return }
          self?.finishCommand(request.requestID, .failure(CommandFailure.timedOut))
        }
        pendingCommands[request.requestID] = PendingCommand(continuation: continuation, timeout: timeout)
        send(.command(.init(subscriptionID: nil, commandRequest: request)))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finishCommand(request.requestID, .failure(CancellationError())) }
    }
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    let clock = clock
    let interval = refreshInterval
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: interval) } catch { return }
        guard let self, self.status == .ready else { return }
        self.send(.list)
      }
    }
  }

  private func finishCommand(_ id: UUID, _ result: Result<MirrorJSON, any Error>) {
    guard let pending = pendingCommands.removeValue(forKey: id) else { return }
    pending.timeout.cancel()
    pending.continuation.resume(with: result)
  }

  private func failPendingCommands(_ error: any Error) {
    for id in Array(pendingCommands.keys) { finishCommand(id, .failure(error)) }
  }

  private func send(_ message: MirrorMessage) { transport?.send(message, closeAfterSending: false) }

  private func receive(_ message: MirrorMessage) {
    switch message.kind {
    case .panes:
      panes = (message.panes ?? []).sorted { ($0.projectName ?? "", $0.title) < ($1.projectName ?? "", $1.title) }
      capabilities = Set(message.capabilities ?? [])
      hostRunID = message.hostRunID
      lastRefreshedAt = Date()
      status = .ready
    case .commandResult:
      guard let response = message.commandResponse else { return }
      finishCommand(response.requestID, .success(response.response))
    case .ended:
      status = .failed(String(localized: "The Host stopped sharing."))
      transport?.close(nil)
    case .failure:
      status = .failed(message.error ?? String(localized: "The Host rejected the request."))
      transport?.close(nil)
    case .ping, .pong:
      break
    default:
      status = .failed(String(localized: "The Host sent an unexpected message."))
      transport?.close(nil)
    }
  }
}
