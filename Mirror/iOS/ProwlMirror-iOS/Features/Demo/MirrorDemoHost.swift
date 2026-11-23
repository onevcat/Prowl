import Foundation

/// The Host of the demo (docs-ai 098): an in-memory Mac whose panes, conversations and screens
/// come from `MirrorDemoContent`. Each connection it serves is a `MirrorTransport`, so the
/// app's sessions and views run unchanged; only the data source differs from a real Host.
/// Answers, messages, Stop and New Session change the shared state, and every connection that
/// mirrors the changed pane hears about it, as from a real Host.
@MainActor
final class MirrorDemoHost {
  /// What the demo Host offers. No `push-v1`: the demo never registers for notifications.
  static let capabilities = [
    "text-v1", "conversation-v1", "history", "refresh", "launch-profile", "agent-input", "shell-send",
    "agent-keys", "shell-keys", "prompt-respond",
  ]

  let hostName: String
  let runID = UUID()
  private(set) var panes: [MirrorDemoContent.Pane]
  private let profiles: [MirrorDemoContent.Profile]
  private let clock: any Clock<Duration>
  private var connections: [WeakConnection] = []
  /// The scripted work of each pane that is running now.
  private var scripts: [UUID: Task<Void, Never>] = [:]
  /// Messages sent while the agent worked; they start a turn when the current one ends.
  private var queued: [UUID: [String]] = [:]
  private var started = false

  init(content: MirrorDemoContent = .standard(), clock: any Clock<Duration> = ContinuousClock()) {
    hostName = content.hostName
    panes = content.panes
    profiles = content.profiles
    self.clock = clock
  }

  /// Plays the work that runs without input, such as the working agent finishing.
  func start() {
    guard !started else { return }
    started = true
    for pane in panes where !pane.autoplay.isEmpty { play(pane.autoplay, on: pane.descriptor.id) }
  }

  func stop() {
    started = false
    for task in scripts.values { task.cancel() }
    scripts = [:]
    for connection in connections { connection.value?.close(nil) }
    connections = []
  }

  func makeTransport() -> any MirrorTransport {
    let connection = Connection(host: self)
    connections.removeAll { $0.value == nil }
    connections.append(WeakConnection(value: connection))
    return connection
  }

  func pane(_ id: UUID) -> MirrorDemoContent.Pane? { panes.first { $0.descriptor.id == id } }

  // MARK: - Commands

  /// Answers one Host command as the Mac's `prowl` command would, in its JSON shape.
  func run(_ command: MirrorCommandRequest.Command) -> MirrorJSON {
    switch command {
    case .list: return listing()
    case .profiles:
      return Self.ok(data: .object(["profiles": .array(profiles.map(\.json))]))
    case .create(let request): return create(request)
    case .agentsInput(let input): return deliver(input)
    case .send(let input): return shell(input)
    case .promptRespond(let answer): return respond(answer)
    case .agentKeys(let input): return keys(input)
    case .agentsDispatch:
      return Self.failure("agents.dispatch", code: "UNSUPPORTED", "The demo starts agents with New Session.")
    }
  }

  private func listing() -> MirrorJSON {
    let items = panes.map { pane -> MirrorJSON in
      var paneObject: [String: MirrorJSON] = ["id": .string(pane.descriptor.id.uuidString)]
      if let agent = pane.descriptor.agent { paneObject["agent"] = .string(agent) }
      return .object([
        "pane": .object(paneObject), "worktree": pane.worktree.json,
        "task": .object(["status": .string(pane.descriptor.agentState == .working ? "working" : "idle")]),
      ])
    }
    return Self.ok(data: .object(["items": .array(items)]))
  }

  private func create(_ request: MirrorCommandRequest.Create) -> MirrorJSON {
    guard case .worktree(let worktreeID) = request.selector,
      let template = panes.first(where: { $0.worktree.id == worktreeID })
    else {
      return Self.failure("create", code: "NOT_FOUND", "The demo Mac has no such worktree.")
    }
    let profile = request.launch.flatMap { launch in profiles.first { $0.id == launch.profile } }
    var pane = MirrorDemoContent.Pane.launched(
      in: template, profile: profile, order: panes.count)
    let prompt = request.launch?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let id = pane.descriptor.id
    pane.append(pane.agentStartEvents(at: Date()), at: Date())
    panes.append(pane)
    if profile != nil, !prompt.isEmpty { play(MirrorDemoContent.reply(to: prompt, agent: pane.agentName), on: id) }
    return Self.ok(
      data: .object([
        "target": .object([
          "worktree": pane.worktree.json,
          "pane": .object(["id": .string(id.uuidString), "title": .string(pane.descriptor.tabTitle ?? "")]),
        ])
      ]))
  }

  private func deliver(_ input: MirrorCommandRequest.Dispatch) -> MirrorJSON {
    guard let id = UUID(uuidString: input.pane), let pane = pane(id), pane.descriptor.agent != nil else {
      return Self.failure("agents.input", code: "NOT_FOUND", "The demo Mac has no such agent pane.")
    }
    if pane.descriptor.agentState == .blocked {
      return Self.failure(
        "agents.input", code: "INPUT_NOT_READY",
        "\(pane.agentName) is waiting on a question. Answer it first.")
    }
    if pane.descriptor.agentState == .working {
      queued[id, default: []].append(input.prompt)
      update(id) {
        $0.append([.demo(.userQueued, .message(.init(text: .init(input.prompt), origin: .human)))], at: Date())
      }
    } else {
      play(MirrorDemoContent.reply(to: input.prompt, agent: pane.agentName), on: id)
    }
    return Self.delivered("agents.input", bytes: input.prompt.utf8.count)
  }

  private func shell(_ input: MirrorShellInput) -> MirrorJSON {
    guard let id = UUID(uuidString: input.selector.value), pane(id) != nil else {
      return Self.failure("send", code: "NOT_FOUND", "The demo Mac has no such pane.")
    }
    update(id) { $0.runShellCommand(input.text) }
    return Self.delivered("send", bytes: input.text.utf8.count)
  }

  private func respond(_ answer: MirrorCommandRequest.PromptRespond) -> MirrorJSON {
    guard let id = UUID(uuidString: answer.pane), let pane = pane(id), let prompt = pane.prompt,
      prompt.id == answer.prompt, let choice = prompt.choices?.first(where: { $0.id == answer.choice })
    else {
      return Self.failure("prompt.respond", code: "PROMPT_CHANGED", "The question on the screen changed.")
    }
    resolve(prompt, choice: choice, on: id)
    return Self.ok(command: "prompt.respond", data: .object(["choice": .string(choice.id)]))
  }

  private func keys(_ input: MirrorCommandRequest.AgentKeys) -> MirrorJSON {
    guard input.isAllowed, let id = UUID(uuidString: input.pane), let pane = pane(id) else {
      return Self.failure("agent.keys", code: "KEYS_REFUSED", "These keys cannot be sent.")
    }
    if input.keys.contains("esc") || input.keys.contains("ctrl-c") {
      if let prompt = pane.prompt, let decline = prompt.choices?.last {
        resolve(prompt, choice: decline, on: id)
      } else if pane.descriptor.agentState == .working {
        interrupt(id)
      }
    }
    return Self.ok(command: "agent.keys", data: .object(["keys": .array(input.keys.map { .string($0) })]))
  }

  // MARK: - Scripts

  private func resolve(_ prompt: MirrorConversationEvent.Prompt, choice: MirrorConversationEvent.Choice, on id: UUID) {
    guard let pane = pane(id) else { return }
    var resolved = prompt
    let declined = choice.label.lowercased().hasPrefix("no")
    resolved.outcome = prompt.kind == .permission ? (declined ? .denied : .allowed) : .answered
    resolved.decidedBy = "mirror"
    update(id) { $0.append([.demo(.promptResolved, .prompt(resolved), source: .screen)], at: Date()) }
    play(pane.answers[choice.id] ?? pane.answers["*"] ?? [], on: id)
  }

  /// Stop: the running tool and the turn end as interrupted, as an agent reports Escape.
  private func interrupt(_ id: UUID) {
    scripts.removeValue(forKey: id)?.cancel()
    update(id) { pane in pane.append(pane.interruptionEvents(), at: Date()) }
    playQueued(id)
  }

  private func play(_ steps: [MirrorDemoContent.Step], on id: UUID) {
    scripts.removeValue(forKey: id)?.cancel()
    guard !steps.isEmpty else {
      playQueued(id)
      return
    }
    let clock = clock
    scripts[id] = Task { [weak self] in
      for step in steps {
        do { try await clock.sleep(for: step.delay) } catch { return }
        guard let self, !Task.isCancelled else { return }
        self.update(id) { $0.append(step.events, at: Date()) }
      }
      guard let self, !Task.isCancelled else { return }
      self.scripts[id] = nil
      self.playQueued(id)
    }
  }

  private func playQueued(_ id: UUID) {
    guard var messages = queued[id], !messages.isEmpty, let pane = pane(id) else { return }
    let message = messages.removeFirst()
    queued[id] = messages
    update(id) {
      $0.append([.demo(.userUnqueued, .message(.init(text: .init(message), origin: .human)))], at: Date())
    }
    play(MirrorDemoContent.reply(to: message, agent: pane.agentName), on: id)
  }

  private func update(_ id: UUID, _ change: (inout MirrorDemoContent.Pane) -> Void) {
    guard let index = panes.firstIndex(where: { $0.descriptor.id == id }) else { return }
    change(&panes[index])
    for connection in connections { connection.value?.paneChanged(id) }
  }

  // MARK: - JSON

  private static func ok(command: String? = nil, data: MirrorJSON) -> MirrorJSON {
    var object: [String: MirrorJSON] = ["ok": .bool(true), "data": data]
    if let command { object["command"] = .string(command) }
    return .object(object)
  }

  private static func delivered(_ command: String, bytes: Int) -> MirrorJSON {
    ok(
      command: command,
      data: .object([
        "input": .object(["bytes": .number(Double(bytes)), "trailing_enter_sent": .bool(true)])
      ]))
  }

  private static func failure(_ command: String, code: String, _ message: String) -> MirrorJSON {
    .object([
      "ok": .bool(false), "command": .string(command),
      "error": .object(["code": .string(code), "message": .string(message)]),
    ])
  }

  private struct WeakConnection {
    weak var value: Connection?
  }

  /// What one connection mirrors, and how far it got.
  private struct DemoSubscription {
    let paneID: UUID
    let lease = UUID()
    let representation: MirrorMessage.Representation
    let includesScreenPrompt: Bool
    var sentSequence: UInt64
    var frameSequence: UInt64 = 0
    var shownPromptID: String?
  }

  // MARK: - Connection

  /// One connection to the demo Host. Messages go out on the next main-actor turn, in order, as
  /// they would arrive from a socket.
  private final class Connection: MirrorTransport {
    var onReady: (() -> Void)?
    var onMessage: ((MirrorMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    var verifiedConfiguration: MirrorSavedConnection? { nil }

    private weak var host: MirrorDemoHost?
    private var subscription: DemoSubscription?
    private var history: MirrorHistory?
    private var outbox: [MirrorMessage] = []
    private var draining = false
    private var closed = false

    init(host: MirrorDemoHost) { self.host = host }

    func start() {
      Task { [weak self] in
        guard let self, !self.closed else { return }
        self.onReady?()
      }
    }

    func close(_ reason: String?) {
      guard !closed else { return }
      closed = true
      subscription = nil
      outbox = []
      onClose?(reason)
    }

    func send(_ message: MirrorMessage, closeAfterSending: Bool) {
      guard !closed, let host else { return }
      switch message {
      case .list:
        emit(
          .panes(
            .init(
              panes: host.panes.map(\.descriptor), capabilities: MirrorDemoHost.capabilities,
              hostRunID: host.runID, hostName: host.hostName)))
      case .subscribe(let payload):
        subscribe(payload, host: host)
      case .refresh:
        if let subscription { sendScreen(subscription.paneID, force: true) }
      case .command(let payload):
        let request = payload.commandRequest
        let response = host.run(request.request.command)
        emit(.commandResult(.init(commandResponse: .init(requestID: request.requestID, response: response))))
      case .commandReceipt:
        // Every demo command answers at once, so no message waits for a receipt.
        break
      case .history(let payload):
        sendHistory(payload)
      case .ping:
        emit(.pong)
      case .acknowledge, .compress, .pong:
        break
      default:
        emit(.failure(.init(error: "UNSUPPORTED: The demo Mac does not answer this request.")))
      }
      if closeAfterSending { close(nil) }
    }

    /// The demo Host changed `id`: send what this connection's subscription has not seen.
    func paneChanged(_ id: UUID) {
      guard subscription?.paneID == id else { return }
      if subscription?.representation == .conversation {
        sendNewEvents()
      } else {
        sendScreen(id, force: false)
      }
    }

    private func subscribe(_ payload: MirrorMessage.SubscribePayload, host: MirrorDemoHost) {
      guard let pane = host.pane(payload.paneID) else {
        emit(.ended(.init(reason: .paneClosed)))
        return
      }
      if payload.representation == .conversation, pane.descriptor.conversation != .available {
        emit(.failure(.init(error: "CONVERSATION_UNSUPPORTED: This pane has no agent conversation.")))
        return
      }
      let since = payload.representation == .conversation ? payload.since ?? 0 : 0
      let subscription = DemoSubscription(
        paneID: pane.descriptor.id, representation: payload.representation == .conversation ? .conversation : .text,
        includesScreenPrompt: payload.includeScreenPrompt == true, sentSequence: since)
      self.subscription = subscription
      history = nil
      emit(.subscribed(.init(paneID: pane.descriptor.id, subscriptionID: subscription.lease, hostRunID: host.runID)))
      if subscription.representation == .conversation {
        let events = pane.events.filter { $0.sequence > since }
        self.subscription?.sentSequence = pane.latestSequence
        emit(
          .conversationSnapshot(
            .init(
              events: events, gap: false, sequence: pane.latestSequence, subscriptionID: subscription.lease,
              session: pane.session)))
      } else {
        sendScreen(pane.descriptor.id, force: true)
      }
    }

    private func sendNewEvents() {
      guard let subscription, let pane = host?.pane(subscription.paneID) else { return }
      let events = pane.events.filter { $0.sequence > subscription.sentSequence }
      guard !events.isEmpty else { return }
      self.subscription?.sentSequence = pane.latestSequence
      emit(
        .conversationEvents(
          .init(events: events, sequence: pane.latestSequence, subscriptionID: subscription.lease)))
    }

    private func sendScreen(_ id: UUID, force: Bool) {
      guard var subscription, subscription.paneID == id, let pane = host?.pane(id) else { return }
      subscription.frameSequence += 1
      emit(
        .textFrame(.init(sequence: subscription.frameSequence, text: pane.screen, subscriptionID: subscription.lease)))
      if subscription.includesScreenPrompt, force || subscription.shownPromptID != pane.prompt?.id {
        subscription.shownPromptID = pane.prompt?.id
        emit(.screenPrompt(.init(prompt: pane.prompt, subscriptionID: subscription.lease)))
      }
      self.subscription = subscription
    }

    private func sendHistory(_ payload: MirrorMessage.HistoryPayload) {
      guard let subscription, payload.subscriptionID == subscription.lease,
        let pane = host?.pane(subscription.paneID)
      else { return }
      if payload.historyID == nil || payload.historyID != history?.id {
        history = MirrorHistory(text: pane.historyText)
      }
      guard let history else { return }
      do {
        let page = try history.page(before: payload.offset ?? history.lines.count)
        emit(
          .historyPage(
            .init(
              historyID: history.id, offset: page.start, lines: page.lines, total: history.lines.count,
              subscriptionID: subscription.lease, capturedAt: history.capturedAt, truncated: history.truncated)))
      } catch {
        emit(
          .failure(
            .init(error: "HISTORY_UNAVAILABLE: \(error.localizedDescription)", subscriptionID: subscription.lease)))
      }
    }

    private func emit(_ message: MirrorMessage) {
      outbox.append(message)
      guard !draining else { return }
      draining = true
      Task { [weak self] in
        guard let self else { return }
        while !self.outbox.isEmpty, !self.closed {
          let next = self.outbox.removeFirst()
          self.onMessage?(next)
        }
        self.draining = false
      }
    }
  }
}
