import Foundation
import Network
import Observation
import Security

@MainActor
@Observable
final class MirrorHost {
  private(set) var isRunning = false
  private(set) var isStarting = false
  private(set) var error: String?
  private(set) var pairingKey = ""
  private(set) var subscriberCount = 0
  var address: String
  var port: String
  var onStarted: (() -> Void)?
  var onStopped: (() -> Void)?
  @ObservationIgnored private let source: any MirrorPaneSource
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var peers: [UUID: MirrorConnection] = [:]
  @ObservationIgnored private var subscriptions: [UUID: Subscription] = [:]
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var versions: [UUID: Int] = [:]
  @ObservationIgnored private var submissionLedger = MirrorSubmissionLedger()
  @ObservationIgnored private var deliveredObservations: [UUID: MirrorAgentState] = [:]
  private(set) var hostRunID: UUID?
  @ObservationIgnored private var connectionAttempts = MirrorConnectionAttempts()

  private struct Subscription {
    let paneID: UUID
    let id = UUID()
    var representation: MirrorMessage.Representation = .terminal
    var gate = MirrorFrameGate()
    var textGate = MirrorTextFrameGate()
    var history: MirrorHistory?
    var agentState: MirrorAgentState?
  }

  init(source: any MirrorPaneSource, defaults: UserDefaults = .standard) {
    self.source = source
    self.defaults = defaults
    address = defaults.string(forKey: "remoteMirrorHostAddress") ?? "0.0.0.0"
    port = defaults.string(forKey: "remoteMirrorHostPort") ?? "7880"
  }

  func start() {
    guard listener == nil else { return }
    error = nil
    do {
      guard let portNumber = UInt16(port), portNumber > 0,
        IPv4Address(address) != nil || IPv6Address(address) != nil
      else { throw MirrorProtocolError.invalidMessage }
      pairingKey = try MirrorPairingCode.generate()
      let parameters = try MirrorConnection.parameters(pairingKey: pairingKey)
      let bindHost: NWEndpoint.Host
      if let ipv4 = IPv4Address(address) {
        bindHost = .ipv4(ipv4)
      } else if let ipv6 = IPv6Address(address) {
        bindHost = .ipv6(ipv6)
      } else {
        throw MirrorProtocolError.invalidMessage
      }
      parameters.requiredLocalEndpoint = .hostPort(
        host: bindHost, port: .init(rawValue: portNumber)!)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      isStarting = true
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, let listener, self.listener === listener else { return }
          switch state {
          case .ready:
            self.hostRunID = UUID()
            self.isRunning = true
            self.isStarting = false
            self.defaults.set(self.address, forKey: "remoteMirrorHostAddress")
            self.defaults.set(self.port, forKey: "remoteMirrorHostPort")
            self.onStarted?()
          case .failed(let error):
            self.stop()
            self.error = error.localizedDescription
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self, weak listener] connection in
        Task { @MainActor in
          guard let self, let listener, self.listener === listener else {
            connection.cancel()
            return
          }
          self.accept(connection)
        }
      }
      listener.start(queue: .main)
    } catch { self.error = "Cannot start Host: \(error.localizedDescription)" }
  }

  func stop() {
    onStopped?()
    listener?.cancel()
    listener = nil
    pollTask?.cancel()
    pollTask = nil
    let connections = Array(peers.values)
    for peer in connections {
      end(peer, reason: .hostStopped)
    }
    peers.removeAll()
    subscriptions.removeAll()
    versions.removeAll()
    hostRunID = nil
    submissionLedger = MirrorSubmissionLedger()
    deliveredObservations.removeAll()
    subscriberCount = 0
    isRunning = false
    isStarting = false
    pairingKey = ""
    connectionAttempts = MirrorConnectionAttempts()
  }

  private func accept(_ connection: NWConnection) {
    guard listener != nil, peers.count < 16, connectionAttempts.accept(now: ProcessInfo.processInfo.systemUptime) else {
      connection.cancel()
      return
    }
    let peer = MirrorConnection(connection)
    peers[peer.id] = peer
    peer.onMessage = { [weak self, weak peer] message in
      guard let self, let peer else { return }
      self.handle(message, from: peer)
    }
    peer.onClose = { [weak self, weak peer] _ in
      guard let self, let peer else { return }
      self.peers.removeValue(forKey: peer.id)
      self.versions.removeValue(forKey: peer.id)
      self.subscriptions.removeValue(forKey: peer.id)
      self.subscriberCount = self.subscriptions.count
      if self.subscriptions.isEmpty {
        self.pollTask?.cancel()
        self.pollTask = nil
      }
    }
    peer.start()
  }

  private func handle(_ message: MirrorMessage, from peer: MirrorConnection) {
    do {
      guard message.version == 1 || versions[peer.id] == 2 else {
        throw MirrorProtocolError.invalidMessage
      }
      switch message.kind {
      case .list:
        if message.supportedVersions?.contains(2) == true { versions[peer.id] = 2 }
        let busy = Set(subscriptions.values.map(\.paneID))
        let panes = source.panes().map {
          MirrorPaneDescriptor(
            id: $0.id, title: $0.title, directory: $0.directory, busy: busy.contains($0.id),
            projectName: $0.projectName, subtitle: $0.subtitle, role: $0.role)
        }
        peer.send(
          MirrorMessage(
            kind: .panes, panes: panes, selectedVersion: versions[peer.id],
            capabilities: versions[peer.id] == 2
              ? ["vt-v1", "text-v1", "takeover", "refresh"]
                + (source.supportsBoundedHistory ? ["history"] : [])
                + (source.supportsSubmission ? ["agent-state", "submit-text"] : []) : nil,
            hostRunID: hostRunID))
      case .subscribe:
        try subscribe(message, peer: peer)
      case .acknowledge:
        try acknowledge(message, peer: peer)
      case .refresh:
        guard message.version == 2, var subscription = subscription(for: message, peer: peer) else {
          throw MirrorProtocolError.invalidMessage
        }
        subscription.gate.requestRefresh()
        subscription.textGate.requestRefresh()
        subscriptions[peer.id] = subscription
      case .input:
        guard let subscription = subscription(for: message, peer: peer),
          subscription.representation == .terminal, let bytes = message.bytes,
          !bytes.isEmpty, bytes.count <= MirrorWire.maximumInput
        else { throw MirrorProtocolError.invalidMessage }
        try source.write(bytes, to: subscription.paneID)
      case .submit:
        try submit(message, peer: peer)
      case .submissionStatus:
        guard message.version == 2, let key = submissionKey(message) else { throw MirrorProtocolError.invalidMessage }
        let outcome =
          key.run == hostRunID
          ? submissionLedger.receipt(key)
          : MirrorSubmitOutcome(status: .unknown, detail: "The Host sharing cycle has changed.")
        peer.send(submissionReply(key, outcome: outcome))
      case .history:
        try sendHistory(message, to: peer)
      default: throw MirrorProtocolError.invalidMessage
      }
    } catch { peer.close(error.localizedDescription) }
  }

  private func subscription(for message: MirrorMessage, peer: MirrorConnection) -> Subscription? {
    guard let subscription = subscriptions[peer.id] else { return nil }
    if versions[peer.id] == 2 {
      guard message.version == 2, message.subscriptionID == subscription.id else { return nil }
    }
    return subscription
  }

  private func acknowledge(_ message: MirrorMessage, peer: MirrorConnection) throws {
    guard var subscription = subscription(for: message, peer: peer), let sequence = message.sequence else {
      throw MirrorProtocolError.invalidMessage
    }
    if subscription.representation == .text {
      try subscription.textGate.acknowledge(sequence)
    } else {
      try subscription.gate.acknowledge(sequence)
    }
    subscriptions[peer.id] = subscription
  }

  private func subscribe(_ message: MirrorMessage, peer: MirrorConnection) throws {
    guard subscriptions[peer.id] == nil, let paneID = message.paneID,
      source.panes().contains(where: { $0.id == paneID })
    else { throw MirrorProtocolError.invalidMessage }
    let modern = versions[peer.id] == 2
    guard !modern || message.version == 2 else { throw MirrorProtocolError.invalidMessage }
    let previous = subscriptions.first { $0.value.paneID == paneID }
    guard previous == nil || (modern && message.intent == .takeover) else {
      peer.send(
        MirrorMessage(kind: .failure, error: "PANE_BUSY: This pane already has a remote mirror."))
      return
    }
    var next = Subscription(
      paneID: paneID, representation: modern ? message.representation ?? .terminal : .terminal)
    // Prepare and encode before revoking the old lease. Capture failure leaves it intact.
    let first = try capture(&next, modern: modern)
    if let first { _ = try MirrorWire.encode(first) }
    if let previous {
      subscriptions.removeValue(forKey: previous.key)
      if let oldPeer = peers[previous.key] { end(oldPeer, reason: .takenOver) }
    }
    subscriptions[peer.id] = next
    subscriberCount = subscriptions.count
    if modern {
      peer.send(
        MirrorMessage(
          version: 2, kind: .subscribed, paneID: paneID,
          subscriptionID: next.id, hostRunID: hostRunID))
    }
    if let first { peer.send(first) }
    if modern, source.supportsSubmission {
      next.agentState = submissionState(paneID)
      subscriptions[peer.id] = next
      peer.send(MirrorMessage(version: 2, kind: .state, subscriptionID: next.id, agentState: next.agentState))
    }
    if pollTask == nil {
      pollTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
          self?.poll()
        }
      }
    }
  }

  private func end(_ peer: MirrorConnection, reason: MirrorMessage.EndReason) {
    if versions[peer.id] == 2 {
      peer.send(MirrorMessage(version: 2, kind: .ended, reason: reason), closeAfterSending: true)
    } else {
      peer.send(MirrorMessage(kind: .failure, error: reason.rawValue), closeAfterSending: true)
    }
  }

  private func capture(_ subscription: inout Subscription, modern: Bool) throws -> MirrorMessage? {
    if subscription.representation == .text {
      guard subscription.textGate.outstanding == nil else { return nil }
      let text = try source.activeText(subscription.paneID)
      guard let sequence = subscription.textGate.offer(text) else { return nil }
      return MirrorMessage(
        version: 2, kind: .textFrame, sequence: sequence,
        text: text, subscriptionID: subscription.id)
    }
    guard subscription.gate.outstanding == nil else { return nil }
    let frame = try source.snapshot(subscription.paneID)
    guard let sequence = subscription.gate.offer(frame) else { return nil }
    return MirrorMessage(
      version: modern ? 2 : 1, kind: .frame, frame: frame,
      sequence: sequence, subscriptionID: modern ? subscription.id : nil)
  }

  private func sendHistory(_ message: MirrorMessage, to peer: MirrorConnection) throws {
    guard var subscription = subscription(for: message, peer: peer) else {
      throw MirrorProtocolError.invalidMessage
    }
    if message.historyID == nil {
      if versions[peer.id] == 2 {
        do {
          guard source.supportsBoundedHistory else { throw MirrorProtocolError.invalidMessage }
          let captured = try source.boundedRetainedText(subscription.paneID)
          subscription.history = MirrorHistory(text: captured.text, truncated: captured.truncated)
        } catch {
          peer.send(
            MirrorMessage(
              version: 2, kind: .failure,
              error: "HISTORY_UNAVAILABLE: Cannot capture history within the supported limits.",
              subscriptionID: subscription.id))
          return
        }
      } else {
        subscription.history = MirrorHistory(text: try source.retainedText(subscription.paneID))
      }
    }
    guard let history = subscription.history,
      message.historyID == nil || message.historyID == history.id
    else {
      throw MirrorProtocolError.invalidMessage
    }
    let page = try history.page(before: message.offset ?? history.lines.count)
    subscriptions[peer.id] = subscription
    peer.send(
      MirrorMessage(
        version: versions[peer.id] == 2 ? 2 : 1, kind: .historyPage, historyID: history.id,
        offset: page.start,
        lines: page.lines, total: history.lines.count,
        subscriptionID: versions[peer.id] == 2 ? subscription.id : nil,
        capturedAt: history.capturedAt, truncated: history.truncated))
  }

  private func submissionKey(_ message: MirrorMessage) -> MirrorSubmissionLedger.Key? {
    guard let run = message.hostRunID, let pane = message.paneID,
      let generation = message.agentGeneration, let submission = message.submissionID
    else { return nil }
    return .init(run: run, pane: pane, generation: generation, submission: submission)
  }

  private func submissionReply(_ key: MirrorSubmissionLedger.Key, outcome: MirrorSubmitOutcome) -> MirrorMessage {
    MirrorMessage(
      version: 2, kind: .submitResult, paneID: key.pane, hostRunID: key.run,
      submissionID: key.submission, agentGeneration: key.generation, result: outcome)
  }

  private func submit(_ message: MirrorMessage, peer: MirrorConnection) throws {
    guard message.version == 2, source.supportsSubmission,
      let subscription = subscription(for: message, peer: peer), subscription.representation == .text,
      let key = submissionKey(message), key.run == hostRunID, key.pane == subscription.paneID,
      let text = message.text, let revision = message.observationRevision
    else { throw MirrorProtocolError.invalidMessage }
    switch submissionLedger.reserve(key, text: text) {
    case .existing(let outcome):
      peer.send(submissionReply(key, outcome: outcome))
      return
    case .refused(let reason):
      peer.send(submissionReply(key, outcome: .init(status: .rejected, detail: reason)))
      return
    case .reserved: break
    }
    let owner = peer.id
    Task { [weak self, weak peer] in
      guard let self, self.hostRunID == key.run else { return }
      let state = self.submissionState(key.pane)
      let outcome: MirrorSubmitOutcome
      if self.subscriptions[owner]?.id != subscription.id || state.generation != key.generation
        || state.revision != revision || !state.canSubmit
      {
        outcome = .init(status: .rejected, detail: "The pane ownership or Agent state changed. Refresh before sending.")
      } else {
        self.deliveredObservations[key.pane] = state
        outcome = await self.source.submit(text, to: key.pane, expected: state)
        if self.hostRunID == key.run, outcome.status == .rejected,
          self.deliveredObservations[key.pane] == state
        {
          self.deliveredObservations.removeValue(forKey: key.pane)
        }
      }
      guard self.hostRunID == key.run else { return }
      let final =
        outcome.status == .pending
        ? MirrorSubmitOutcome(status: .unknown, detail: "The Agent did not confirm delivery.") : outcome
      self.submissionLedger.finish(key, outcome: final)
      peer?.send(self.submissionReply(key, outcome: final))
    }
  }

  private func submissionState(_ pane: UUID) -> MirrorAgentState {
    let state = source.submissionState(pane)
    guard let delivered = deliveredObservations[pane], delivered.generation == state.generation,
      state.revision <= delivered.revision
    else { return state }
    return MirrorAgentState(
      generation: state.generation, revision: state.revision, canSubmit: false,
      reason: "Waiting for updated Agent state after delivery.", observedAt: state.observedAt)
  }

  private func poll() {
    if !deliveredObservations.isEmpty {
      let live = Set(source.panes().map(\.id))
      deliveredObservations = deliveredObservations.filter { live.contains($0.key) }
    }
    for (id, var subscription) in subscriptions {
      guard let peer = peers[id] else { continue }
      guard source.panes().contains(where: { $0.id == subscription.paneID }) else {
        subscriptions.removeValue(forKey: id)
        subscriberCount = subscriptions.count
        end(peer, reason: .paneClosed)
        continue
      }
      do {
        if versions[id] == 2, source.supportsSubmission {
          let state = submissionState(subscription.paneID)
          if subscription.agentState?.generation != state.generation
            || subscription.agentState?.revision != state.revision
            || subscription.agentState?.canSubmit != state.canSubmit
            || subscription.agentState?.reason != state.reason
          {
            subscription.agentState = state
            subscriptions[id] = subscription
            peer.send(MirrorMessage(version: 2, kind: .state, subscriptionID: subscription.id, agentState: state))
          }
        }
        if let frame = try capture(&subscription, modern: versions[id] == 2) {
          subscriptions[id] = subscription
          peer.send(frame)
        }
      } catch {
        peer.close("Host pane is unavailable: \(error.localizedDescription)")
      }
    }
  }
}

nonisolated struct MirrorConnectionAttempts {
  private var attempts: [TimeInterval] = []

  mutating func accept(now: TimeInterval) -> Bool {
    guard now.isFinite else { return false }
    attempts.removeAll { now >= $0 + 60 }
    guard attempts.count < 12 else { return false }
    attempts.append(now)
    return true
  }
}
