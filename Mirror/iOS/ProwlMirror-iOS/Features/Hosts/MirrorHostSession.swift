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
  /// The Mac's computer name from the last roster (docs-ai 089).
  private(set) var hostName: String?
  /// Called once the Host verified the device; carries the credential-bearing configuration.
  var onVerified: ((MirrorSavedConnection) -> Void)?

  /// False when another attempt cannot help: the Host rejected this device's key. The Host
  /// counts each rejected attempt against this address and stops answering it after 12 in a
  /// minute, which would shut out a new pairing too.
  var retriesAutomatically: Bool {
    if case .failed(let reason) = status { return reason != MirrorConnection.unrecognizedDevice }
    return true
  }

  var supportsConversation: Bool { capabilities.contains("conversation-v1") }
  var supportsLaunch: Bool { capabilities.contains("launch-profile") }
  var supportsShellLaunch: Bool { capabilities.contains("launch-shell") }

  @ObservationIgnored private var transport: (any MirrorTransport)?
  @ObservationIgnored private var generation = UUID()
  /// The pane this device just stopped mirroring, and how many rosters may still call it busy.
  @ObservationIgnored private var releasedPane: (id: UUID, rosters: Int)?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var pendingCommands: [UUID: PendingCommand] = [:]
  @ObservationIgnored private var connectTimeout: Task<Void, Never>?
  /// How long a connection may stay unanswered before it counts as failed.
  static let connectTimeoutDuration: Duration = .seconds(10)
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
        self.connectTimeout?.cancel()
        self.connectTimeout = nil
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
        self.connectTimeout?.cancel()
        self.connectTimeout = nil
        self.transport = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.failPendingCommands(CommandFailure.disconnected)
        self.status = .failed(reason ?? String(localized: "Connection lost."))
      }
      channel.start()
      // A wrong code or a silent Host must not leave the screen on "Connecting…" forever.
      let clock = clock
      connectTimeout = Task { [weak self] in
        do { try await clock.sleep(for: Self.connectTimeoutDuration) } catch { return }
        guard let self, self.generation == attempt, self.status == .connecting else { return }
        self.transport?.close(nil)
        self.transport = nil
        self.status = .failed(String(localized: "The Host did not answer. Check the address, port and code."))
      }
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    generation = UUID()
    connectTimeout?.cancel()
    connectTimeout = nil
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

  /// This device closed its mirror of `id`. The Host may answer a roster request before it has
  /// seen that connection end, and the row would say "Mirrored elsewhere" about this device.
  /// The next rosters do not mark the pane busy; one asked for now replaces them soon.
  func paneReleased(_ id: UUID) {
    releasedPane = (id, 2)
    if let index = panes.firstIndex(where: { $0.id == id }), panes[index].busy { panes[index].busy = false }
    refresh()
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
      var listed = (message.panes ?? []).sorted { ($0.projectName ?? "", $0.title) < ($1.projectName ?? "", $1.title) }
      if let released = releasedPane {
        if let index = listed.firstIndex(where: { $0.id == released.id }) { listed[index].busy = false }
        releasedPane = released.rosters > 1 ? (released.id, released.rosters - 1) : nil
      }
      panes = listed
      capabilities = Set(message.capabilities ?? [])
      hostRunID = message.hostRunID
      if let name = message.hostName { hostName = name }
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
