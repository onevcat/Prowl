import Foundation
import Network
import Observation

@MainActor
@Observable
final class MirrorSession: Identifiable {
  enum Status: Equatable {
    case disconnected, connecting, choosingPane, subscribing, live, takenOver, hostStopped,
      paneClosed, incompatible

    var label: String {
      switch self {
      case .disconnected: "Connection lost"
      case .connecting: "Connecting…"
      case .choosingPane: "Choose a pane"
      case .subscribing: "Opening mirror…"
      case .live: "Live"
      case .takenOver: "Taken over by another device"
      case .hostStopped: "Host stopped sharing"
      case .paneClosed: "Host pane closed"
      case .incompatible: "Update Host required"
      }
    }
  }

  let id = UUID()
  private(set) var configuration: MirrorSavedConnection
  private(set) var panes: [MirrorPaneDescriptor] = []
  private(set) var pane: MirrorPaneDescriptor?
  private(set) var status: Status = .disconnected
  private(set) var text = ""
  private(set) var revision: UInt64 = 0
  private(set) var updatedAt: Date?
  private(set) var error: String?
  private(set) var supportsHistory = false
  private(set) var supportsLaunch = false
  @ObservationIgnored private var pendingCommand: PendingCommand?
  @ObservationIgnored private var commandTimeout: Task<Void, Never>?
  @ObservationIgnored private let clock: any Clock<Duration>

  private struct PendingCommand {
    let id: UUID
    let continuation: CheckedContinuation<MirrorJSON, any Error>
  }
  private enum CommandFailure: LocalizedError {
    case unavailable, disconnected, timedOut
    var errorDescription: String? {
      switch self {
      case .unavailable: "Host command service is unavailable or another command is pending."
      case .disconnected: "Connection lost before Host confirmed the command."
      case .timedOut: "Host did not confirm the command in time."
      }
    }
  }
  private(set) var historyLines: [String] = []
  private(set) var historyOffset = 0
  private(set) var historyCapturedAt: Date?
  private(set) var historyTruncated = false
  private(set) var isLoadingHistory = false
  var showsHistory = false
  var liveReadingOffset: CGFloat = 0
  var historyReadingOffset: CGFloat = 0
  @ObservationIgnored private var historyID: UUID?
  @ObservationIgnored private var historyBytes = 0
  var draft = "" {
    didSet { if draft != oldValue { draftRevision = UUID() } }
  }
  var supportsSubmission: Bool { supportsLaunch }
  var isComposing = false
  private(set) var submission: Submission?
  @ObservationIgnored private var draftRevision = UUID()
  @ObservationIgnored private var hostRunID: UUID?

  struct Submission {
    let id: UUID
    let text: String
    let paneID: UUID
    let runID: UUID
    let draftRevision: UUID
    let configuration: MirrorSavedConnection
    var outcome: MirrorDeliveryOutcome
  }

  var canSubmit: Bool {
    status == .live && supportsSubmission && !isComposing
      && subscriptionID != nil && hostRunID != nil
      && submission?.outcome.status != .pending && submission?.outcome.status != .unknown
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.utf8.count <= MirrorWire.maximumInput
  }

  var submissionHint: String {
    if let submission, submission.outcome.status != .accepted { return submission.outcome.detail }
    if !supportsSubmission { return "This Host has not enabled message submission for this pane." }
    if status != .live { return "Reconnect to the pane before sending." }
    return "Host checks Agent readiness when you send."
  }
  var followsLatest = true
  var onVerifiedConnection: ((MirrorSavedConnection) -> Void)?
  @ObservationIgnored private var transport: (any MirrorTransport)?
  @ObservationIgnored private var subscriptionID: UUID?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var intent: MirrorMessage.Intent = .ifFree
  @ObservationIgnored private var userDisconnected = false
  @ObservationIgnored private var supportsRefresh = false
  @ObservationIgnored private let makeTransport: (MirrorSavedConnection) throws -> any MirrorTransport

  init(
    configuration: MirrorSavedConnection,
    clock: any Clock<Duration> = ContinuousClock(),
    makeTransport: @escaping (MirrorSavedConnection) throws -> any MirrorTransport = {
      configuration in
      MirrorRemoteConnection(configuration: configuration)
    }
  ) {
    self.clock = clock
    self.configuration = configuration
    self.makeTransport = makeTransport
  }

  func connect() {
    guard transport == nil else { return }
    userDisconnected = false
    error = nil
    status = .connecting
    supportsLaunch = false
    generation = UUID()
    let attempt = generation
    do {
      let channel = try makeTransport(configuration)
      transport = channel
      channel.onReady = { [weak self] in
        guard let self, self.generation == attempt else { return }
        if let verified = self.transport?.verifiedConfiguration { self.configuration = verified }
        self.send(.list)
      }
      channel.onMessage = { [weak self] message in
        guard let self, self.generation == attempt else { return }
        self.receive(message)
      }
      channel.onClose = { [weak self] reason in
        guard let self, self.generation == attempt else { return }
        self.transport = nil
        self.finishCommand(.failure(CommandFailure.disconnected))
        self.subscriptionID = nil
        self.markDeliveryUncertain()
        self.isLoadingHistory = false
        if self.status == .live || self.status == .connecting || self.status == .subscribing
          || self.status == .choosingPane
        {
          self.status = .disconnected
        }
        self.error = self.error ?? reason
      }
      channel.start()
    } catch {
      status = .disconnected
      self.error = error.localizedDescription
    }
  }

  func select(_ pane: MirrorPaneDescriptor) {
    guard status == .choosingPane else { return }
    self.pane = pane
    intent = .takeover
    subscribe()
  }

  func refreshPanes() {
    guard status == .choosingPane else { return }
    send(.list)
  }

  func retry(takeover: Bool = false) {
    guard transport == nil else { return }
    intent = takeover ? .takeover : .ifFree
    connect()
  }

  func foreground() {
    guard !userDisconnected else { return }
    if status == .disconnected {
      retry()
    } else if status == .live, supportsRefresh, let subscriptionID {
      send(.refresh(.init(subscriptionID: subscriptionID)))
      querySubmission()
    }
  }

  func updateConnection(_ configuration: MirrorSavedConnection) {
    disconnect()
    if self.configuration.address != configuration.address
      || self.configuration.port != configuration.port
    {
      pane = nil
      panes = []
      text = ""
      revision = 0
      updatedAt = nil
      liveReadingOffset = 0
      historyReadingOffset = 0
      historyID = nil
      historyLines = []
      historyBytes = 0
      historyOffset = 0
      historyCapturedAt = nil
      showsHistory = false
    }
    self.configuration = configuration
    intent = .ifFree
    connect()
  }

  func disconnect() {
    userDisconnected = true
    finishCommand(.failure(CommandFailure.disconnected))
    generation = UUID()
    let old = transport
    transport = nil
    old?.onClose = nil
    old?.close(nil)
    subscriptionID = nil
    markDeliveryUncertain()
    isLoadingHistory = false
    status = .disconnected
  }

  func command(_ command: MirrorCommandRequest.Command) async throws -> MirrorJSON {
    let liveListing: Bool = {
      if case .list = command { return status == .live }
      return false
    }()
    guard status == .choosingPane || liveListing, supportsLaunch, transport != nil,
      pendingCommand == nil
    else {
      throw CommandFailure.unavailable
    }
    let request = MirrorCommandRequest(requestID: UUID(), request: .init(command: command))
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pendingCommand = PendingCommand(id: request.requestID, continuation: continuation)
        let clock = clock
        commandTimeout = Task { [weak self] in
          do { try await clock.sleep(for: .seconds(30)) } catch { return }
          guard self?.pendingCommand?.id == request.requestID else { return }
          self?.finishCommand(.failure(CommandFailure.timedOut))
        }
        send(.command(.init(subscriptionID: subscriptionID, commandRequest: request)))
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.pendingCommand?.id == request.requestID else { return }
        self?.finishCommand(.failure(CancellationError()))
      }
    }
  }

  private func finishCommand(_ result: Result<MirrorJSON, any Error>) {
    commandTimeout?.cancel()
    commandTimeout = nil
    let pending = pendingCommand
    pendingCommand = nil
    pending?.continuation.resume(with: result)
  }

  func submitDraft() {
    guard canSubmit, let pane, let hostRunID, let subscriptionID else { return }
    let request = Submission(
      id: UUID(), text: draft, paneID: pane.id, runID: hostRunID,
      draftRevision: draftRevision, configuration: configuration,
      outcome: .init(status: .pending, detail: "Host is checking readiness and dispatching…"))
    submission = request
    Task { await routeSubmission(request, lease: subscriptionID) }
    let clock = clock
    Task { [weak self] in
      do { try await clock.sleep(for: .seconds(30)) } catch { return }
      guard self?.submission?.id == request.id else { return }
      self?.markDeliveryUncertain()
    }
  }

  private func routeSubmission(_ request: Submission, lease: UUID) async {
    do {
      let listing = try await command(.list(.init()))
      guard status == .live, subscriptionID == lease, submission?.id == request.id else { return }
      let input = try MirrorInputRoute.command(
        listing: listing, paneID: request.paneID, text: request.text)
      send(
        .command(
          .init(
            subscriptionID: lease,
            commandRequest: .init(requestID: request.id, request: .init(command: input)))))
    } catch {
      guard submission?.id == request.id else { return }
      submission?.outcome = .init(
        status: .rejected, detail: error.localizedDescription + " No input was sent.")
    }
  }

  private func receiveDispatch(_ response: MirrorCommandResponse) {
    guard var current = submission, current.id == response.requestID,
      current.configuration == configuration,
      current.outcome.status == .pending || current.outcome.status == .unknown
    else { return }
    struct Result: Decodable {
      struct Payload: Decodable {
        struct Dispatch: Decodable { let id: String }
        struct Input: Decodable {
          let bytes: Int
          let trailing_enter_sent: Bool
        }
        let dispatch: Dispatch?
        let input: Input?
      }
      struct Failure: Decodable {
        let code: String
        let message: String
      }
      let ok: Bool
      let command: String?
      let data: Payload?
      let error: Failure?
    }
    guard let result = try? response.response.decode(Result.self) else {
      markDeliveryUncertain()
      return
    }
    if result.ok, let dispatch = result.data?.dispatch {
      current.outcome = .init(
        status: .accepted, detail: "Dispatched (" + dispatch.id + "). Agent completion is separate."
      )
      if current.draftRevision == draftRevision { draft = "" }
    } else if result.ok, result.command == "send", let input = result.data?.input,
      input.bytes == current.text.utf8.count, input.trailing_enter_sent
    {
      current.outcome = .init(
        status: .accepted, detail: "Sent to the shell. Command completion is separate.")
      if current.draftRevision == draftRevision { draft = "" }
    } else if let error = result.error,
      !["REMOTE_COMMAND_UNCONFIRMED", "DISPATCH_FAILED", "SEND_FAILED"].contains(error.code)
    {
      current.outcome = .init(status: .rejected, detail: error.message)
    } else {
      current.outcome = .init(
        status: .unknown, detail: "Delivery is unconfirmed. Check Host before sending again.")
    }
    submission = current
  }

  func querySubmission() {
    guard let submission, let subscriptionID, submission.configuration == configuration,
      submission.runID == hostRunID,
      submission.outcome.status == .pending || submission.outcome.status == .unknown
    else { return }
    send(.commandReceipt(.init(subscriptionID: subscriptionID, commandReceiptID: submission.id)))
  }

  func acknowledgeUnknownSubmission() {
    guard submission?.outcome.status == .unknown else { return }
    submission = nil
  }

  private func markDeliveryUncertain() {
    if submission?.outcome.status == .pending {
      submission?.outcome = .init(
        status: .unknown,
        detail: "Delivery is unconfirmed. Check the receipt or Host output before sending again.")
    }
  }

  func loadHistory(refresh: Bool = false) {
    guard status == .live, supportsHistory, !isLoadingHistory, let subscriptionID else { return }
    if refresh {
      historyReadingOffset = 0
      historyID = nil
      historyLines = []
      historyBytes = 0
      historyOffset = 0
      historyCapturedAt = nil
    }
    guard historyID == nil || historyOffset > 0 else { return }
    isLoadingHistory = true
    showsHistory = true
    send(
      .history(
        .init(
          historyID: historyID, offset: historyID == nil ? nil : historyOffset,
          subscriptionID: subscriptionID)))
  }

  private func subscribe() {
    guard let pane else { return }
    status = .subscribing
    revision = 0
    subscriptionID = nil
    send(
      .subscribe(.init(paneID: pane.id, representation: .text, intent: intent)))
  }

  private func send(_ message: MirrorMessage) { transport?.send(message, closeAfterSending: false) }

  private func receive(_ message: MirrorMessage) {
    switch message.kind {
    case .panes:
      guard message.capabilities?.contains("text-v1") == true else {
        status = .incompatible
        error = "Update Prowl on this Host to enable mobile text mirrors."
        transport?.close(nil)
        return
      }
      supportsLaunch = message.capabilities?.contains("launch-profile") == true
      supportsRefresh = message.capabilities?.contains("refresh") == true
      supportsHistory = message.capabilities?.contains("history") == true
      if supportsSubmission { querySubmission() }
      panes = message.panes ?? []
      onVerifiedConnection?(configuration)
      if let pane {
        guard panes.contains(where: { $0.id == pane.id }) else {
          status = .paneClosed
          transport?.close(nil)
          return
        }
        subscribe()
      } else {
        status = .choosingPane
      }
    case .commandResult:
      guard let response = message.commandResponse else {
        invalidMessage()
        return
      }
      if response.requestID == submission?.id {
        receiveDispatch(response)
        return
      }
      guard response.requestID == pendingCommand?.id else { return }
      finishCommand(.success(response.response))
    case .subscribed:
      guard status == .subscribing, message.paneID == pane?.id,
        message.hostRunID != nil, let lease = message.subscriptionID
      else {
        invalidMessage()
        return
      }
      subscriptionID = lease
      hostRunID = message.hostRunID
      historyID = nil
      historyLines = []
      historyBytes = 0
      historyOffset = 0
      historyCapturedAt = nil
      isLoadingHistory = false
      showsHistory = false
      querySubmission()
    case .textFrame:
      guard let lease = subscriptionID, message.subscriptionID == lease,
        let sequence = message.sequence, sequence > revision, let replacement = message.text,
        replacement.utf8.count <= MirrorWire.maximumPayload / 8
      else {
        invalidMessage()
        return
      }
      text = replacement
      revision = sequence
      updatedAt = Date()
      status = .live
      send(.acknowledge(.init(sequence: sequence, subscriptionID: lease)))
    case .historyPage:
      guard isLoadingHistory, subscriptionID != nil,
        message.subscriptionID == subscriptionID, let id = message.historyID,
        let offset = message.offset, let lines = message.lines,
        let total = message.total, let capturedAt = message.capturedAt,
        total >= 0, total <= MirrorHistory.maximumBytes + 1,
        offset >= 0, offset <= total, capturedAt.isFinite, lines.count <= MirrorHistory.pageSize,
        offset + lines.count == (historyID == nil ? total : historyOffset),
        historyID == nil || historyID == id
      else {
        invalidMessage()
        return
      }
      let pageBytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
      guard pageBytes <= MirrorHistory.maximumBytes + 1 - historyBytes else {
        invalidMessage()
        return
      }
      historyBytes += pageBytes
      historyID = id
      historyOffset = offset
      historyLines.insert(contentsOf: lines, at: 0)
      historyCapturedAt = Date(timeIntervalSince1970: capturedAt)
      historyTruncated = message.truncated ?? false
      isLoadingHistory = false
    case .ended:
      guard let reason = message.reason else {
        invalidMessage()
        return
      }
      switch reason {
      case .takenOver: status = .takenOver
      case .hostStopped: status = .hostStopped
      case .paneClosed: status = .paneClosed
      }
      transport?.close(nil)
    case .failure:
      if message.error?.hasPrefix("HISTORY_UNAVAILABLE") == true,
        message.subscriptionID == subscriptionID
      {
        isLoadingHistory = false
        error = message.error
        return
      }
      if message.error?.hasPrefix("PANE_BUSY") == true { status = .takenOver }
      error = message.error ?? "Host rejected the request."
      transport?.close(nil)
    default: invalidMessage()
    }
  }

  private func invalidMessage() {
    error = "Host sent an invalid mirror message."
    transport?.close(error)
  }
}

nonisolated struct MirrorDeliveryOutcome: Equatable, Sendable {
  enum Status: String, Sendable { case pending, accepted, rejected, unknown }
  let status: Status
  let detail: String
}
