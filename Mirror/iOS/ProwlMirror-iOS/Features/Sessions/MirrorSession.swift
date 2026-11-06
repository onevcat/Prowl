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

  /// How the pane is shown: the agent's conversation or the terminal screen (docs-ai 088).
  enum Mode: String, Equatable, Sendable {
    case conversation
    case screen
  }

  let id = UUID()
  private(set) var configuration: MirrorSavedConnection
  private(set) var panes: [MirrorPaneDescriptor] = []
  private(set) var pane: MirrorPaneDescriptor?
  @ObservationIgnored private var expectedLaunch: MirrorPaneDescriptor?
  @ObservationIgnored private var latestRosterDescriptor: MirrorPaneDescriptor?
  @ObservationIgnored private var expectationTask: Task<Void, Never>?
  private(set) var mode: Mode = .screen
  private(set) var conversation = MirrorConversationStore()
  private(set) var supportsConversation = false
  /// The Host answers screen prompts from here (docs-ai 089 S4).
  private(set) var supportsPromptRespond = false
  /// The Host presses navigation and control keys in agent panes (docs-ai 089 S5).
  private(set) var supportsAgentKeys = false
  /// Why the last key press or Stop was refused, until the next one; the composer shows it in
  /// both modes.
  private(set) var keyRefusal: String?
  @ObservationIgnored private var sendingKeys = false

  /// The Host presses keys in shell panes too (capability `shell-keys`).
  private(set) var supportsShellKeys = false

  /// The Host and the pane take keys: the key bar shows.
  var keysAvailable: Bool { status == .live && supportsAgentKeys && (pane?.agent != nil || supportsShellKeys) }
  /// A key can go now; not while a message may still be being delivered.
  var canSendKeys: Bool { keysAvailable && !isDeliveringMessage }

  /// The composer's Stop button: an agent works in the pane and a key can go (docs-ai 089 S5).
  /// Stop presses Escape, which interrupts an agent but not a shell command; a shell has ⌃C.
  var canStopAgent: Bool { pane?.agent != nil && agentState == .working && canSendKeys }

  /// Presses `keys` in the pane on the Mac: the Terminal key bar and Stop. One press at a time;
  /// a press while another is in flight is dropped rather than queued.
  func sendKeys(_ keys: [String]) {
    guard canSendKeys, let pane, !sendingKeys else { return }
    sendingKeys = true
    keyRefusal = nil
    Task { [weak self] in
      var refusal: String?
      do {
        guard let self else { return }
        let response = try await self.command(.agentKeys(.init(pane: pane.id.uuidString, keys: keys)))
        struct Result: Decodable {
          struct Failure: Decodable { let message: String }
          let ok: Bool
          let error: Failure?
        }
        let result = try response.decode(Result.self)
        if !result.ok { refusal = result.error?.message ?? String(localized: "The Host refused the keys.") }
      } catch {
        refusal = error.localizedDescription
      }
      guard let self else { return }
      self.sendingKeys = false
      self.keyRefusal = refusal
    }
  }

  /// A message the Host may still be delivering. It holds the connection's only Host command,
  /// so a prompt answer or a key must wait: a second command would close the connection (089
  /// review S5-R4). An unknown outcome counts too, because a timeout is no proof that the Host
  /// finished. It ends with a receipt or with "I've Checked", as for the next message.
  var isDeliveringMessage: Bool {
    submission?.outcome.status == .pending || submission?.outcome.status == .unknown
  }

  /// The answer this device sent to an open prompt, until the prompt resolves or the Host
  /// refuses it.
  private(set) var promptAnswer: PromptAnswer?

  struct PromptAnswer: Equatable {
    enum State: Equatable {
      case sending
      /// The Host pressed the keys; the prompt resolves when the agent moves on.
      case delivered
      case refused(String)
    }

    let promptID: String
    let choice: String
    var state: State
  }

  /// Sends `choice` for the open screen prompt. The Host checks that the screen still shows
  /// this prompt before it presses any key, and never retries.
  func answerPrompt(_ promptID: String, choice: String) {
    guard status == .live, supportsPromptRespond, let pane else { return }
    // One answer per prompt: a refused one may be tried again, a sent one may not.
    if let promptAnswer, promptAnswer.promptID == promptID, promptAnswer.state == .sending
      || promptAnswer.state == .delivered
    {
      return
    }
    guard !isDeliveringMessage else {
      promptAnswer = .init(
        promptID: promptID, choice: choice,
        state: .refused(String(localized: "Wait until the Mac confirms your message, then answer.")))
      return
    }
    promptAnswer = .init(promptID: promptID, choice: choice, state: .sending)
    Task { [weak self] in
      let state: PromptAnswer.State
      do {
        guard let self else { return }
        let response = try await self.command(
          .promptRespond(.init(pane: pane.id.uuidString, prompt: promptID, choice: choice)))
        struct Result: Decodable {
          struct Failure: Decodable { let message: String }
          let ok: Bool
          let error: Failure?
        }
        let result = try response.decode(Result.self)
        state = result.ok ? .delivered : .refused(result.error?.message ?? String(localized: "The Host refused the answer."))
      } catch {
        state = .refused(error.localizedDescription)
      }
      guard let self, self.promptAnswer?.promptID == promptID, self.promptAnswer?.choice == choice else { return }
      self.promptAnswer?.state = state
    }
  }
  /// A representation switch that keeps the connection: the next `subscribed` is not a reconnect.
  @ObservationIgnored private var resumesConversation = false
  private(set) var status: Status = .disconnected
  private(set) var text = ""
  private(set) var revision: UInt64 = 0
  private(set) var updatedAt: Date?
  private(set) var error: String?
  private(set) var supportsHistory = false
  private(set) var supportsLaunch = false
  private(set) var supportsRemoteScroll = false
  private(set) var isScrolling = false
  private(set) var scrollError: String?
  private(set) var completedScroll: ScrollCompletion?
  private(set) var scrollAtTop: Bool?
  private(set) var scrollAtBottom: Bool?
  @ObservationIgnored private var supportsScrollState = false
  @ObservationIgnored private var pendingScrollState: MirrorMessage.ScrollStatePayload?
  @ObservationIgnored private var pendingScroll: PendingScroll?
  @ObservationIgnored private var scrollTimeout: Task<Void, Never>?
  /// The Host runs commands in shell panes at their prompt (capability `shell-send`).
  private(set) var supportsShellSend = false
  @ObservationIgnored private var supportsAgentInput = false
  @ObservationIgnored private var pendingCommand: PendingCommand?
  @ObservationIgnored private var commandTimeout: Task<Void, Never>?
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let scrollConfirmationTimeout: Duration

  private struct PendingCommand {
    let id: UUID
    let continuation: CheckedContinuation<MirrorJSON, any Error>
  }
  private struct PendingScroll {
    let id: UUID
    let direction: MirrorMessage.ScrollDirection
    let subscriptionID: UUID
    let baseline: UInt64
  }
  struct ScrollCompletion: Equatable {
    let id: UUID
    let direction: MirrorMessage.ScrollDirection
  }
  var canScroll: Bool {
    status == .live && supportsRemoteScroll && subscriptionID != nil && !isScrolling && !showsHistory
  }
  func canScroll(_ direction: MirrorMessage.ScrollDirection) -> Bool {
    canScroll && (direction == .upward ? scrollAtTop != true : scrollAtBottom != true)
  }
  private enum CommandFailure: LocalizedError {
    case unavailable, disconnected, timedOut, shellUnavailable, agentInputUnavailable
    var errorDescription: String? {
      switch self {
      case .unavailable: "Host command service is unavailable or another command is pending."
      case .disconnected: "Connection lost before Host confirmed the command."
      case .timedOut: "Host did not confirm the command in time."
      case .agentInputUnavailable: "Update Host to support interactive Agent input."
      case .shellUnavailable: "Update Prowl on the Mac to run shell commands from here."
      }
    }
  }
  private(set) var historyLines: [String] = []
  private(set) var historyOffset = 0
  private(set) var historyCapturedAt: Date?
  private(set) var historyTruncated = false
  private(set) var isLoadingHistory = false
  var showsHistory = false
  /// The reading view writes it on every scroll and reads it only when it appears, so a change
  /// must not update views.
  @ObservationIgnored var liveReadingAnchor: MirrorReadingAnchor?
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
    scrollConfirmationTimeout: Duration = .seconds(5),
    makeTransport: @escaping (MirrorSavedConnection) throws -> any MirrorTransport = {
      configuration in
      MirrorRemoteConnection(configuration: configuration)
    }
  ) {
    self.clock = clock
    self.scrollConfirmationTimeout = scrollConfirmationTimeout
    self.configuration = configuration
    self.makeTransport = makeTransport
  }

  func connect() {
    guard transport == nil else { return }
    userDisconnected = false
    error = nil
    status = .connecting
    supportsLaunch = false
    supportsShellSend = false
    supportsAgentInput = false
    supportsRemoteScroll = false
    supportsScrollState = false
    clearScrollState()
    clearScroll()
    scrollError = nil
    completedScroll = nil
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
        self.clearScroll()
        self.clearScrollState()
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
    intent = pane.busy ? .takeover : .ifFree
    subscribe()
  }

  /// Takes the newer descriptor of the open pane from the Host roster: its title, agent and
  /// state change after the pane opens (a new Profile pane gets its agent detected later).
  func refreshDescriptor(_ descriptor: MirrorPaneDescriptor) {
    guard pane?.id == descriptor.id else { return }
    let merged = merging(descriptor)
    if pane != merged { pane = merged }
  }

  /// A pane this device just launched from a Profile: until the Host detects the agent, the
  /// roster reports a Shell. Keep the launched agent and title for a short while so the
  /// composer and title do not flip to "Shell" (docs-ai 089 D1). When the time runs out
  /// without detection, the Host's latest descriptor wins, even if it never changed.
  func expectAgent(of launched: MirrorPaneDescriptor, for duration: Duration = .seconds(30)) {
    guard launched.agent != nil else { return }
    expectedLaunch = launched
    expectationTask?.cancel()
    let clock = clock
    expectationTask = Task { [weak self] in
      do { try await clock.sleep(for: duration) } catch { return }
      self?.endLaunchExpectation()
    }
  }

  private func endLaunchExpectation() {
    expectationTask?.cancel()
    expectationTask = nil
    guard expectedLaunch != nil else { return }
    expectedLaunch = nil
    if let latest = latestRosterDescriptor, latest.id == pane?.id, pane != latest { pane = latest }
  }

  private func merging(_ descriptor: MirrorPaneDescriptor) -> MirrorPaneDescriptor {
    latestRosterDescriptor = descriptor
    guard let expected = expectedLaunch, expected.id == descriptor.id else { return descriptor }
    guard descriptor.agent == nil else {
      endLaunchExpectation()
      return descriptor
    }
    var merged = descriptor
    merged.agent = expected.agent
    merged.subtitle = expected.subtitle
    merged.conversation = descriptor.conversation == .unsupported ? nil : descriptor.conversation
    return merged
  }

  /// Connects and subscribes to a pane chosen from a Host roster, in the given mode.
  func open(_ pane: MirrorPaneDescriptor, mode: Mode) {
    self.pane = pane
    self.mode = mode == .conversation && pane.conversation == .available ? .conversation : .screen
    intent = pane.busy ? .takeover : .ifFree
    connect()
  }

  /// Switches the representation on the same connection; the Host replaces the subscription.
  func switchMode(_ newMode: Mode) {
    guard newMode != mode, status == .live || status == .subscribing else { return }
    guard newMode == .screen || supportsConversation else { return }
    mode = newMode
    resumesConversation = newMode == .conversation && conversation.latestSequence > 0
    subscribe()
  }

  /// The agent's state now. The conversation stream reports it in Chat; in Terminal that stream
  /// is paused and its last status is stale, so the roster's state counts (089 review S5-R1). A
  /// pane whose agent is gone has no agent state, whatever the paused stream last said.
  var agentState: MirrorConversationEvent.AgentState? {
    switch mode {
    case .conversation: conversation.status?.state ?? pane?.agentState
    case .screen: pane?.agent == nil ? nil : pane?.agentState ?? conversation.status?.state
    }
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
      liveReadingAnchor = nil
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
    // Ending here, not only pausing the timer, keeps a reconnect from showing the launched
    // agent forever (R089-P0-003).
    endLaunchExpectation()
    finishCommand(.failure(CommandFailure.disconnected))
    generation = UUID()
    let old = transport
    transport = nil
    old?.onClose = nil
    old?.close(nil)
    subscriptionID = nil
    clearScroll()
    clearScrollState()
    markDeliveryUncertain()
    isLoadingHistory = false
    status = .disconnected
  }

  func command(_ command: MirrorCommandRequest.Command) async throws -> MirrorJSON {
    let liveListing: Bool = {
      switch command {
      // The Host runs one command per connection; a message it is still delivering holds it.
      case .promptRespond, .agentKeys: return status == .live && !isDeliveringMessage
      case .list: return status == .live
      default: return false
      }
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
      outcome: .init(status: .pending, detail: "Host is checking readiness and sending…"))
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
      if case .agentsInput = input, !supportsAgentInput { throw CommandFailure.agentInputUnavailable }
      if case .send = input, !supportsShellSend { throw CommandFailure.shellUnavailable }
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
        struct Input: Decodable {
          let bytes: Int
          let trailing_enter_sent: Bool
        }
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
    if result.ok, ["send", "agents.input"].contains(result.command ?? ""), let input = result.data?.input,
      input.bytes == current.text.utf8.count, input.trailing_enter_sent
    {
      current.outcome = .init(
        status: .accepted, detail: "Sent. Agent completion is separate.")
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

  func scroll(_ direction: MirrorMessage.ScrollDirection) {
    guard canScroll(direction), let subscriptionID else { return }
    let request = PendingScroll(id: UUID(), direction: direction, subscriptionID: subscriptionID, baseline: revision)
    pendingScroll = request
    isScrolling = true
    scrollError = nil
    followsLatest = false
    let clock = clock
    let timeout = scrollConfirmationTimeout
    scrollTimeout = Task { [weak self] in
      do { try await clock.sleep(for: timeout) } catch { return }
      guard self?.pendingScroll?.id == request.id else { return }
      self?.clearScroll()
      self?.scrollError = String(
        localized: "Host did not confirm the scroll in time. Check the screen before trying again.")
    }
    send(.scroll(.init(requestID: request.id, direction: direction, subscriptionID: subscriptionID)))
  }

  private func clearScroll() {
    scrollTimeout?.cancel()
    scrollTimeout = nil
    pendingScroll = nil
    isScrolling = false
  }

  private func clearScrollState() {
    pendingScrollState = nil
    scrollAtTop = nil
    scrollAtBottom = nil
  }

  private func receiveScrollState(_ message: MirrorMessage) {
    guard case .scrollState(let state) = message,
      state.subscriptionID == subscriptionID, state.sequence > revision
    else { return }
    guard supportsScrollState else {
      invalidMessage()
      return
    }
    pendingScrollState = state
  }

  private func commitScrollState(sequence: UInt64) -> Bool {
    guard supportsScrollState else { return true }
    guard let state = pendingScrollState, state.sequence == sequence,
      state.subscriptionID == subscriptionID
    else { return false }
    pendingScrollState = nil
    scrollAtTop = state.atTop
    scrollAtBottom = state.atBottom
    return true
  }

  private func receiveScrollResult(_ message: MirrorMessage) {
    guard let pendingScroll, message.scrollRequestID == pendingScroll.id,
      message.subscriptionID == pendingScroll.subscriptionID, subscriptionID == pendingScroll.subscriptionID
    else { return }
    guard let sequence = message.sequence, sequence > pendingScroll.baseline, sequence <= revision else {
      invalidMessage()
      return
    }
    completedScroll = ScrollCompletion(id: pendingScroll.id, direction: pendingScroll.direction)
    clearScroll()
  }

  private func consumeScrollFailure(_ message: MirrorMessage) -> Bool {
    guard message.error?.hasPrefix("SCROLL_UNAVAILABLE") == true || message.error?.hasPrefix("SCROLL_BUSY") == true
    else {
      return false
    }
    guard let pendingScroll, message.subscriptionID == pendingScroll.subscriptionID,
      message.scrollRequestID == pendingScroll.id
    else { return true }
    clearScroll()
    scrollError = message.error
    return true
  }

  private func subscribe() {
    guard let pane else { return }
    status = .subscribing
    revision = 0
    subscriptionID = nil
    clearScroll()
    clearScrollState()
    if mode == .conversation {
      let since = conversation.latestSequence > 0 ? conversation.latestSequence : nil
      resumesConversation = since != nil
      send(.subscribe(.init(paneID: pane.id, representation: .conversation, intent: intent, since: since)))
      return
    }
    send(
      .subscribe(
        .init(
          paneID: pane.id, representation: .text, intent: intent,
          includeScrollState: supportsScrollState ? true : nil)))
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
      supportsAgentInput = message.capabilities?.contains("agent-input") == true
      supportsShellSend = message.capabilities?.contains("shell-send") == true
      supportsRefresh = message.capabilities?.contains("refresh") == true
      supportsHistory = message.capabilities?.contains("history") == true
      supportsRemoteScroll = message.capabilities?.contains("remote-scroll") == true
      supportsScrollState = message.capabilities?.contains("scroll-state-v1") == true
      supportsConversation = message.capabilities?.contains("conversation-v1") == true
      supportsPromptRespond = message.capabilities?.contains("prompt-respond") == true
      supportsAgentKeys = message.capabilities?.contains("agent-keys") == true
      supportsShellKeys = message.capabilities?.contains("shell-keys") == true
      if supportsSubmission { querySubmission() }
      panes = message.panes ?? []
      onVerifiedConnection?(configuration)
      if let pane {
        guard let current = panes.first(where: { $0.id == pane.id }) else {
          status = .paneClosed
          transport?.close(nil)
          return
        }
        self.pane = merging(current)
        if mode == .conversation, !supportsConversation { mode = .screen }
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
    case .conversationSnapshot, .conversationEvents:
      guard mode == .conversation, let lease = subscriptionID, message.subscriptionID == lease,
        let sequence = message.sequence, let events = message.conversationEvents,
        events.count <= MirrorConversationStore.maximumEvents
      else {
        invalidMessage()
        return
      }
      if case .conversationSnapshot(let payload) = message {
        conversation.apply(
          snapshot: events, gap: payload.gap, sequence: sequence, session: payload.session,
          resumed: resumesConversation)
        resumesConversation = false
      } else {
        conversation.apply(events: events, sequence: sequence)
      }
      updatedAt = Date()
      status = .live
      if !events.isEmpty { send(.acknowledge(.init(sequence: sequence, subscriptionID: lease))) }
    case .textFrame:
      guard let lease = subscriptionID, message.subscriptionID == lease,
        let sequence = message.sequence, sequence > revision, let replacement = message.text,
        replacement.utf8.count <= MirrorWire.maximumPayload / 8, commitScrollState(sequence: sequence)
      else {
        invalidMessage()
        return
      }
      text = replacement
      revision = sequence
      updatedAt = Date()
      status = .live
      send(.acknowledge(.init(sequence: sequence, subscriptionID: lease)))
    case .scrollResult:
      receiveScrollResult(message)
    case .scrollState:
      receiveScrollState(message)
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
      if consumeScrollFailure(message) { return }
      if message.error?.hasPrefix("HISTORY_UNAVAILABLE") == true,
        message.subscriptionID == subscriptionID
      {
        isLoadingHistory = false
        error = message.error
        return
      }
      if message.error?.hasPrefix("CONVERSATION_UNSUPPORTED") == true, mode == .conversation {
        // The pane has no supported agent right now; the screen still works.
        mode = .screen
        subscribe()
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
