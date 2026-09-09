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
  private(set) var hostRunID: UUID?

  private struct Subscription {
    let paneID: UUID
    let id = UUID()
    var representation: MirrorMessage.Representation = .terminal
    var gate = MirrorFrameGate()
    var textGate = MirrorTextFrameGate()
    var history: MirrorHistory?
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
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        error = "Unable to generate a pairing key."
        return
      }
      pairingKey = bytes.map { String(format: "%02x", $0) }.joined()
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
    subscriberCount = 0
    isRunning = false
    isStarting = false
    pairingKey = ""
  }

  private func accept(_ connection: NWConnection) {
    guard listener != nil, peers.count < 16 else {
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
            capabilities: versions[peer.id] == 2 ? ["vt-v1", "text-v1", "takeover"] : nil,
            hostRunID: hostRunID))
      case .subscribe:
        try subscribe(message, peer: peer)
      case .acknowledge:
        guard var subscription = subscription(for: message, peer: peer),
          let sequence = message.sequence
        else {
          throw MirrorProtocolError.invalidMessage
        }
        if subscription.representation == .text {
          try subscription.textGate.acknowledge(sequence)
        } else {
          try subscription.gate.acknowledge(sequence)
        }
        subscriptions[peer.id] = subscription
      case .input:
        guard let subscription = subscription(for: message, peer: peer),
          subscription.representation == .terminal, let bytes = message.bytes,
          !bytes.isEmpty, bytes.count <= MirrorWire.maximumInput
        else { throw MirrorProtocolError.invalidMessage }
        try source.write(bytes, to: subscription.paneID)
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
    guard subscription.representation == .terminal else {
      peer.send(
        MirrorMessage(
          version: 2, kind: .failure,
          error: "HISTORY_UNAVAILABLE: Bounded mobile history is not available."))
      return
    }
    if message.historyID == nil {
      let text = try source.retainedText(subscription.paneID)
      subscription.history = MirrorHistory(text: text)
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
        subscriptionID: versions[peer.id] == 2 ? subscription.id : nil))
  }

  private func poll() {
    for (id, var subscription) in subscriptions {
      guard let peer = peers[id] else { continue }
      guard source.panes().contains(where: { $0.id == subscription.paneID }) else {
        subscriptions.removeValue(forKey: id)
        subscriberCount = subscriptions.count
        end(peer, reason: .paneClosed)
        continue
      }
      do {
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
