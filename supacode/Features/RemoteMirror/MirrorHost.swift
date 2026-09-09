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
  @ObservationIgnored private let source: any MirrorPaneSource
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var peers: [UUID: MirrorConnection] = [:]
  @ObservationIgnored private var subscriptions: [UUID: Subscription] = [:]
  @ObservationIgnored private var pollTask: Task<Void, Never>?

  private struct Subscription {
    let paneID: UUID
    var gate = MirrorFrameGate()
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
      parameters.requiredLocalEndpoint = .hostPort(host: bindHost, port: .init(rawValue: portNumber)!)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      isStarting = true
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, let listener, self.listener === listener else { return }
          switch state {
          case .ready:
            self.isRunning = true
            self.isStarting = false
            self.defaults.set(self.address, forKey: "remoteMirrorHostAddress")
            self.defaults.set(self.port, forKey: "remoteMirrorHostPort")
          case .failed(let error):
            self.stop()
            self.error = error.localizedDescription
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.start(queue: .main)
    } catch { self.error = "Cannot start Host: \(error.localizedDescription)" }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    pollTask?.cancel()
    pollTask = nil
    let connections = Array(peers.values)
    peers.removeAll()
    subscriptions.removeAll()
    subscriberCount = 0
    isRunning = false
    isStarting = false
    pairingKey = ""
    for peer in connections { peer.close() }
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
      switch message.kind {
      case .list:
        let busy = Set(subscriptions.values.map(\.paneID))
        let panes = source.panes().map {
          MirrorPaneDescriptor(id: $0.id, title: $0.title, directory: $0.directory, busy: busy.contains($0.id))
        }
        peer.send(MirrorMessage(kind: .panes, panes: panes))
      case .subscribe:
        guard subscriptions[peer.id] == nil, let paneID = message.paneID,
          source.panes().contains(where: { $0.id == paneID })
        else {
          throw MirrorProtocolError.invalidMessage
        }
        guard !subscriptions.values.contains(where: { $0.paneID == paneID }) else {
          peer.send(MirrorMessage(kind: .failure, error: "PANE_BUSY: This pane already has a remote mirror."))
          return
        }
        subscriptions[peer.id] = Subscription(paneID: paneID)
        subscriberCount = subscriptions.count
        poll()
        if pollTask == nil {
          pollTask = Task { [weak self] in
            while !Task.isCancelled {
              do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
              self?.poll()
            }
          }
        }
      case .acknowledge:
        guard var subscription = subscriptions[peer.id], let sequence = message.sequence else {
          throw MirrorProtocolError.invalidMessage
        }
        try subscription.gate.acknowledge(sequence)
        subscriptions[peer.id] = subscription
      case .input:
        guard let subscription = subscriptions[peer.id], let bytes = message.bytes,
          !bytes.isEmpty, bytes.count <= MirrorWire.maximumInput
        else { throw MirrorProtocolError.invalidMessage }
        try source.write(bytes, to: subscription.paneID)
      case .history:
        try sendHistory(message, to: peer)
      default: throw MirrorProtocolError.invalidMessage
      }
    } catch { peer.close(error.localizedDescription) }
  }

  private func sendHistory(_ message: MirrorMessage, to peer: MirrorConnection) throws {
    guard var subscription = subscriptions[peer.id] else {
      throw MirrorProtocolError.invalidMessage
    }
    if message.historyID == nil {
      let text = try source.retainedText(subscription.paneID)
      subscription.history = MirrorHistory(text: text)
    }
    guard let history = subscription.history, message.historyID == nil || message.historyID == history.id else {
      throw MirrorProtocolError.invalidMessage
    }
    let page = try history.page(before: message.offset ?? history.lines.count)
    subscriptions[peer.id] = subscription
    peer.send(
      MirrorMessage(
        kind: .historyPage, historyID: history.id, offset: page.start,
        lines: page.lines, total: history.lines.count))
  }

  private func poll() {
    for (id, var subscription) in subscriptions {
      guard let peer = peers[id] else { continue }
      guard source.panes().contains(where: { $0.id == subscription.paneID }) else {
        peer.close("Host pane closed.")
        continue
      }
      guard subscription.gate.outstanding == nil else { continue }
      let frame: MirrorFrame
      do { frame = try source.snapshot(subscription.paneID) } catch {
        peer.close("Host pane is unavailable: \(error.localizedDescription)")
        continue
      }
      if let sequence = subscription.gate.offer(frame) {
        subscriptions[id] = subscription
        peer.send(MirrorMessage(kind: .frame, frame: frame, sequence: sequence))
      }
    }
  }
}
