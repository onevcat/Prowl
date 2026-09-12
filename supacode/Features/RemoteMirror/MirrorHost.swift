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
  @ObservationIgnored var commandService: MirrorCommandService?
  @ObservationIgnored private var commandPeers: [UUID: MirrorCommandRequest] = [:]
  @ObservationIgnored private var commandDevices: [UUID: UUID] = [:]
  var onStarted: (() -> Void)?
  var onStopped: (() -> Void)?
  @ObservationIgnored private let enabled: Bool
  @ObservationIgnored private let source: any MirrorPaneSource
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var retiringListener: NWListener?
  @ObservationIgnored private var peers: [UUID: MirrorConnection] = [:]
  @ObservationIgnored private var pendingPeers: [UUID: MirrorConnection] = [:]
  @ObservationIgnored private var pendingOrder: [UUID] = []
  private(set) var pendingHandshakeCount = 0
  static let maximumPendingHandshakes = 8
  @ObservationIgnored private var subscriptions: [UUID: Subscription] = [:]
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  private(set) var hostRunID: UUID?
  @ObservationIgnored private var connectionAttempts = MirrorConnectionAttempts()

  private(set) var onlineDeviceIDs: Set<UUID> = []
  private(set) var devices: [MirrorPairedDevice] = []
  private(set) var pairingExpiresAt: Date?
  @ObservationIgnored private var identity: MirrorHostIdentity?
  @ObservationIgnored private var pairingTask: Task<Void, Never>?
  @ObservationIgnored private var challenges: [UUID: Data] = [:]
  @ObservationIgnored private var pendingPairings: [UUID: MirrorDeviceCredential] = [:]
  @ObservationIgnored private var devicePeers: [UUID: UUID] = [:]
  @ObservationIgnored private var authenticationDeadlines: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let loadIdentity: () throws -> MirrorHostIdentity?
  @ObservationIgnored private let saveIdentity: (MirrorHostIdentity) throws -> Void

  func isOnline(_ device: UUID) -> Bool { onlineDeviceIDs.contains(device) }

  func addDevice() {
    guard isRunning, !isStarting else { return }
    do {
      pairingKey = try MirrorPairingCode.generate()
      pairingExpiresAt = Date().addingTimeInterval(60)
      pairingTask?.cancel()
      let clock = clock
      pairingTask = Task { [weak self] in
        do { try await clock.sleep(for: .seconds(60)) } catch { return }
        self?.expirePairing()
      }
      try rebuildListener()
    } catch { self.error = error.localizedDescription }
  }

  private func expirePairing() {
    pairingKey = ""
    pairingExpiresAt = nil
    pairingTask?.cancel()
    pairingTask = nil
    do { if isRunning { try rebuildListener() } } catch { self.error = error.localizedDescription }
  }

  func revoke(_ deviceID: UUID) {
    guard var next = identity else { return }
    next.devices.removeAll { $0.id == deviceID }
    do {
      try saveIdentity(next)
      identity = next
      devices = next.devices
      for (peerID, owner) in commandDevices where owner == deviceID {
        cancelCommand(peerID, includingCreate: true)
      }
      for (peerID, owner) in devicePeers where owner == deviceID {
        peers[peerID]?.close("Device access was revoked.")
      }
      try rebuildListener()
    } catch { self.error = error.localizedDescription }
  }

  private struct Subscription {
    let paneID: UUID
    let id = UUID()
    var representation: MirrorMessage.Representation = .terminal
    var gate = MirrorFrameGate()
    var textGate = MirrorTextFrameGate()
    var history: MirrorHistory?
  }

  init(
    source: any MirrorPaneSource, defaults: UserDefaults = .standard, enabled: Bool,
    clock: any Clock<Duration> = ContinuousClock(),
    loadIdentity: @escaping () throws -> MirrorHostIdentity? = {
      try MirrorCredentialVault.load(MirrorHostIdentity.self, account: "host")
    },
    saveIdentity: @escaping (MirrorHostIdentity) throws -> Void = {
      try MirrorCredentialVault.save($0, account: "host")
    }
  ) {
    self.clock = clock
    self.loadIdentity = loadIdentity
    self.saveIdentity = saveIdentity
    self.enabled = enabled
    self.source = source
    self.defaults = defaults
    address = defaults.string(forKey: "remoteMirrorHostAddress") ?? "0.0.0.0"
    port = defaults.string(forKey: "remoteMirrorHostPort") ?? "7880"
  }

  func start() {
    // Code security: hidden experimental UI must not leave a reachable listener.
    guard enabled, !isStarting, !isRunning, listener == nil else { return }
    error = nil
    do {
      guard let portNumber = UInt16(port), portNumber > 0,
        IPv4Address(address) != nil || IPv6Address(address) != nil
      else { throw MirrorProtocolError.invalidMessage }
      let saved = try loadIdentity() ?? MirrorHostIdentity(id: UUID(), devices: [])
      try saveIdentity(saved)
      identity = saved
      devices = saved.devices
      hostRunID = UUID()
      isStarting = true
      try rebuildListener()
    } catch {
      self.error = "Cannot start Host: \(error.localizedDescription)"
      isStarting = false
    }
  }

  private func rebuildListener() throws {
    isStarting = true
    if retiringListener != nil { return }
    if listener != nil {
      retireListener()
      return
    }
    try installListener()
  }

  private func retireListener() {
    guard let previous = listener else { return }
    listener = nil
    retiringListener = previous
    previous.stateUpdateHandler = { [weak self, weak previous] state in
      guard case .cancelled = state else { return }
      Task { @MainActor in
        guard let self, let previous, self.retiringListener === previous else { return }
        self.retiringListener = nil
        guard self.hostRunID != nil else { return }
        do { try self.installListener() } catch {
          self.stop()
          self.error = error.localizedDescription
        }
      }
    }
    previous.cancel()
  }

  private func installListener() throws {
    guard let identity, let portNumber = UInt16(port), portNumber > 0 else {
      throw MirrorProtocolError.invalidMessage
    }
    var keys = identity.devices.map { ($0.id.uuidString, $0.key) }
    if !pairingKey.isEmpty {
      keys.append(("pair", Data(try MirrorPairingCode.normalized(pairingKey).utf8)))
    }
    // An unpairable listener still requires an unpredictable key, never certificate fallback.
    if keys.isEmpty { keys.append(("closed", try MirrorAuthentication.randomKey())) }
    let parameters = try MirrorConnection.parameters(keys: keys)
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
          self.isRunning = true
          self.isStarting = false
          self.defaults.set(self.address, forKey: "remoteMirrorHostAddress")
          self.defaults.set(self.port, forKey: "remoteMirrorHostPort")
          self.completePairings()
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
  }

  func stop() {
    onStopped?()
    pairingTask?.cancel()
    pairingTask = nil
    pairingExpiresAt = nil
    for task in authenticationDeadlines.values { task.cancel() }
    authenticationDeadlines.removeAll()
    challenges.removeAll()
    pendingPairings.removeAll()
    devicePeers.removeAll()
    onlineDeviceIDs.removeAll()
    hostRunID = nil
    retireListener()
    pollTask?.cancel()
    pollTask = nil
    let connections = Array(peers.values)
    let pending = Array(pendingPeers.values)
    pendingPeers.removeAll()
    pendingOrder.removeAll()
    pendingHandshakeCount = 0
    for peer in pending { peer.close() }
    for peerID in commandPeers.keys { cancelCommand(peerID, includingCreate: true) }
    for peer in connections {
      end(peer, reason: .hostStopped)
    }
    peers.removeAll()
    commandPeers.removeAll()
    commandDevices.removeAll()
    subscriptions.removeAll()
    hostRunID = nil
    subscriberCount = 0
    isRunning = false
    isStarting = false
    pairingKey = ""
    connectionAttempts = MirrorConnectionAttempts()
  }

  private func accept(_ connection: NWConnection) {
    guard listener != nil, case .hostPort(let address, _) = connection.endpoint,
      connectionAttempts.allows(
        source: String(describing: address), now: ProcessInfo.processInfo.systemUptime)
    else {
      connection.cancel()
      return
    }
    let sourceAddress = String(describing: address)
    // Code security: incomplete handshakes never consume authenticated capacity.
    // Evict the oldest pending connection so a silent full pool can still admit a valid client.
    if pendingOrder.count >= Self.maximumPendingHandshakes, let oldest = pendingOrder.first {
      pendingPeers[oldest]?.close()
    }
    let peer = MirrorConnection(connection, handshakeTimeout: .seconds(5))
    pendingPeers[peer.id] = peer
    pendingOrder.append(peer.id)
    pendingHandshakeCount = pendingPeers.count
    peer.onReady = { [weak self, weak peer] in
      guard let self, let peer, self.pendingPeers[peer.id] === peer else { return }
      self.pendingPeers.removeValue(forKey: peer.id)
      self.pendingOrder.removeAll { $0 == peer.id }
      self.pendingHandshakeCount = self.pendingPeers.count
      guard self.listener != nil, self.peers.count < 16 else {
        peer.close()
        return
      }
      do {
        guard let identity = self.identity else { throw MirrorProtocolError.invalidMessage }
        let nonce = try MirrorAuthentication.randomKey()
        self.peers[peer.id] = peer
        self.challenges[peer.id] = nonce
        peer.send(.challenge(.init(hostID: identity.id, nonce: nonce)))
        let clock = self.clock
        self.authenticationDeadlines[peer.id] = Task { [weak peer] in
          do { try await clock.sleep(for: .seconds(5)) } catch { return }
          peer?.close("Device authentication timed out.")
        }
      } catch { peer.close(error.localizedDescription) }
    }
    peer.onHandshakeFailure = { [weak self, weak peer] in
      guard let self, let peer, self.pendingPeers[peer.id] === peer else { return }
      self.connectionAttempts.recordFailure(
        source: sourceAddress, now: ProcessInfo.processInfo.systemUptime)
    }
    peer.onMessage = { [weak self, weak peer] message in
      guard let self, let peer, self.peers[peer.id] === peer else { return }
      if self.devicePeers[peer.id] == nil {
        self.authenticate(message, peer: peer)
      } else {
        self.handle(message, from: peer)
      }
    }
    peer.onClose = { [weak self, weak peer] _ in
      guard let self, let peer else { return }
      self.pendingPeers.removeValue(forKey: peer.id)
      self.pendingOrder.removeAll { $0 == peer.id }
      self.pendingHandshakeCount = self.pendingPeers.count
      self.authenticationDeadlines.removeValue(forKey: peer.id)?.cancel()
      self.challenges.removeValue(forKey: peer.id)
      self.pendingPairings.removeValue(forKey: peer.id)
      self.devicePeers.removeValue(forKey: peer.id)
      self.onlineDeviceIDs = Set(self.devicePeers.values)
      self.cancelCommand(peer.id)
      self.peers.removeValue(forKey: peer.id)
      // Accepted create requests can outlive a lost connection. Keep their device
      // ownership until completion so explicit revoke or stop can still cancel them.
      self.subscriptions.removeValue(forKey: peer.id)
      self.subscriberCount = self.subscriptions.count
      if self.subscriptions.isEmpty {
        self.pollTask?.cancel()
        self.pollTask = nil
      }
    }
    peer.start()
  }

  private func authenticate(_ message: MirrorMessage, peer: MirrorConnection) {
    do {
      guard var identity, let nonce = challenges[peer.id] else {
        throw MirrorProtocolError.invalidMessage
      }
      switch message {
      case .authenticate(let request):
        // Code security: TLS membership alone is insufficient; prove this specific device's secret.
        guard let device = identity.devices.first(where: { $0.id == request.deviceID }),
          MirrorAuthentication.verify(
            request.proof, key: device.key, challenge: .init(hostID: identity.id, nonce: nonce), purpose: "device",
            identity: device.id.uuidString)
        else {
          throw MirrorProtocolError.invalidMessage
        }
        if let index = identity.devices.firstIndex(where: { $0.id == device.id }) {
          identity.devices[index].lastSeen = Date()
        }
        try saveIdentity(identity)
        self.identity = identity
        devices = identity.devices
        devicePeers[peer.id] = device.id
        onlineDeviceIDs = Set(devicePeers.values)
        challenges.removeValue(forKey: peer.id)
        authenticationDeadlines.removeValue(forKey: peer.id)?.cancel()
        peer.send(.authenticated(identity.id))
      case .pair(let request):
        guard let expires = pairingExpiresAt, expires > Date(), !pairingKey.isEmpty,
          !request.name.isEmpty, request.name.utf8.count <= 240,
          !request.name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          }),
          identity.devices.count < 64,
          MirrorAuthentication.verify(
            request.proof,
            key: Data(try MirrorPairingCode.normalized(pairingKey).utf8),
            challenge: .init(hostID: identity.id, nonce: nonce), purpose: "pair", identity: request.name)
        else {
          throw MirrorProtocolError.invalidMessage
        }
        let device = MirrorPairedDevice(
          id: UUID(), name: request.name,
          key: try MirrorAuthentication.randomKey(), pairedAt: Date())
        identity.devices.append(device)
        try saveIdentity(identity)
        self.identity = identity
        devices = identity.devices
        // Consume before any other peer can pair; a lost response requires a new pairing window.
        pendingPairings[peer.id] = .init(hostID: identity.id, deviceID: device.id, key: device.key)
        expirePairing()
      default: throw MirrorProtocolError.invalidMessage
      }
    } catch {
      if case .hostPort(let address, _) = peer.connection.endpoint {
        connectionAttempts.recordFailure(
          source: String(describing: address), now: ProcessInfo.processInfo.systemUptime)
      }
      peer.close("Device authentication failed or pairing expired.")
    }
  }

  private func completePairings() {
    let pending = pendingPairings
    pendingPairings.removeAll()
    for (peerID, credential) in pending {
      guard devices.contains(where: { $0.id == credential.deviceID }) else {
        peers[peerID]?.close("Device access was revoked.")
        continue
      }
      // The client reconnects immediately with this key, so the replacement listener must be ready.
      peers[peerID]?.send(.paired(credential), closeAfterSending: true)
    }
  }

  private func handle(_ message: MirrorMessage, from peer: MirrorConnection) {
    do {
      guard let hostRunID else { throw MirrorProtocolError.invalidMessage }
      switch message.kind {
      case .list:
        let busy = Set(subscriptions.values.map(\.paneID))
        let panes = source.panes().map {
          MirrorPaneDescriptor(
            id: $0.id, title: $0.title, directory: $0.directory, busy: busy.contains($0.id),
            projectName: $0.projectName, subtitle: $0.subtitle, role: $0.role)
        }
        peer.send(
          .panes(
            .init(
              panes: panes,
              capabilities: ["vt-v1", "text-v1", "takeover", "refresh"]
                + (commandService != nil
                  ? ["launch-profile", "agents-dispatch"] : [])
                + (source.supportsBoundedHistory ? ["history"] : []), hostRunID: hostRunID)))
      case .command:
        try handleCommand(message, peer: peer)
      case .commandReceipt:
        try handleReceipt(message, peer: peer)
      case .subscribe:
        try subscribe(message, peer: peer)
      case .acknowledge:
        try acknowledge(message, peer: peer)
      case .refresh:
        guard var subscription = subscription(for: message, peer: peer) else {
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
      case .history:
        try sendHistory(message, to: peer)
      default: throw MirrorProtocolError.invalidMessage
      }
    } catch { peer.close(error.localizedDescription) }
  }

  private func handleCommand(_ message: MirrorMessage, peer: MirrorConnection) throws {
    guard let service = commandService, let request = message.commandRequest
    else { throw MirrorProtocolError.invalidMessage }
    let lease: UUID?
    // Code security: commands cannot escape the authenticated connection’s current pane lease.
    if let paneID = request.request.command.targetPaneID {
      guard let active = subscription(for: message, peer: peer),
        paneID == active.paneID
      else { throw MirrorProtocolError.invalidMessage }
      lease = active.id
    } else {
      if subscriptions[peer.id] != nil {
        guard case .list = request.request.command,
          let active = subscription(for: message, peer: peer)
        else { throw MirrorProtocolError.invalidMessage }
        lease = active.id
      } else {
        lease = nil
      }
    }
    if let pending = commandPeers[peer.id] {
      guard pending == request else { throw MirrorProtocolError.invalidMessage }
      return
    }
    commandPeers[peer.id] = request
    commandDevices[peer.id] = devicePeers[peer.id]
    let peerID = peer.id
    Task { @MainActor [weak self, weak peer] in
      let response = await service.execute(request) { [weak self, weak peer] in
        guard let self, let peer, self.peers[peer.id] === peer else { return false }
        return lease == nil || self.subscriptions[peer.id]?.id == lease
      }
      guard let self else { return }
      self.commandPeers.removeValue(forKey: peerID)
      self.commandDevices.removeValue(forKey: peerID)
      guard let peer, self.peers[peerID] === peer else { return }
      peer.send(.commandResult(.init(commandResponse: response)))
    }
  }

  private func cancelCommand(_ peerID: UUID, includingCreate: Bool = false) {
    guard let request = commandPeers[peerID],
      includingCreate || request.request.command.targetPaneID != nil
    else {
      return
    }
    commandService?.cancel(request.requestID)
  }

  private func handleReceipt(_ message: MirrorMessage, peer: MirrorConnection) throws {
    guard let active = subscription(for: message, peer: peer),
      let requestID = message.commandReceiptID, let service = commandService
    else {
      throw MirrorProtocolError.invalidMessage
    }
    Task { @MainActor [weak self, weak peer] in
      let response = await service.receipt(requestID, paneID: active.paneID)
      guard let self, let peer, self.subscriptions[peer.id]?.id == active.id else { return }
      peer.send(.commandResult(.init(commandResponse: response)))
    }
  }

  private func subscription(for message: MirrorMessage, peer: MirrorConnection) -> Subscription? {
    guard let subscription = subscriptions[peer.id] else { return nil }
    guard message.subscriptionID == subscription.id else { return nil }
    return subscription
  }

  private func acknowledge(_ message: MirrorMessage, peer: MirrorConnection) throws {
    guard var subscription = subscription(for: message, peer: peer), let sequence = message.sequence
    else {
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
    guard let hostRunID, subscriptions[peer.id] == nil, let paneID = message.paneID,
      let representation = message.representation,
      source.panes().contains(where: { $0.id == paneID })
    else { throw MirrorProtocolError.invalidMessage }
    let previous = subscriptions.first { $0.value.paneID == paneID }
    guard previous == nil || message.intent == .takeover else {
      peer.send(
        .failure(
          .init(error: "PANE_BUSY: This pane already has a remote mirror.", subscriptionID: nil)))
      return
    }
    var next = Subscription(
      paneID: paneID, representation: representation)
    // Prepare and encode before revoking the old lease. Capture failure leaves it intact.
    let first = try capture(&next)
    if let first { _ = try MirrorWire.encode(first) }
    if let previous {
      subscriptions.removeValue(forKey: previous.key)
      if let oldPeer = peers[previous.key] { end(oldPeer, reason: .takenOver) }
    }
    subscriptions[peer.id] = next
    subscriberCount = subscriptions.count
    peer.send(.subscribed(.init(paneID: paneID, subscriptionID: next.id, hostRunID: hostRunID)))
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
    cancelCommand(peer.id)
    peer.send(.ended(.init(reason: reason)), closeAfterSending: true)
  }

  private func capture(_ subscription: inout Subscription) throws -> MirrorMessage? {
    if subscription.representation == .text {
      guard subscription.textGate.outstanding == nil else { return nil }
      let captured = try source.textSnapshot(subscription.paneID)
      let text = captured.text
      guard
        let sequence = subscription.textGate.offer(
          text, columns: captured.columns, rows: captured.rows, truncated: captured.truncated)
      else { return nil }
      return .textFrame(
        .init(
          columns: captured.columns, rows: captured.rows, truncated: captured.truncated,
          sequence: sequence, text: text, subscriptionID: subscription.id))
    }
    guard subscription.gate.outstanding == nil else { return nil }
    let frame = try source.snapshot(subscription.paneID)
    guard let sequence = subscription.gate.offer(frame) else { return nil }
    return .frame(.init(frame: frame, sequence: sequence, subscriptionID: subscription.id))
  }

  private func sendHistory(_ message: MirrorMessage, to peer: MirrorConnection) throws {
    guard var subscription = subscription(for: message, peer: peer) else {
      throw MirrorProtocolError.invalidMessage
    }
    if message.historyID == nil {
      do {
        do {
          guard source.supportsBoundedHistory else { throw MirrorProtocolError.invalidMessage }
          let captured = try source.boundedRetainedText(subscription.paneID)
          subscription.history = MirrorHistory(text: captured.text, truncated: captured.truncated)
        } catch {
          peer.send(
            .failure(
              .init(
                error: "HISTORY_UNAVAILABLE: Cannot capture history within the supported limits.",
                subscriptionID: subscription.id)))
          return
        }
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
      .historyPage(
        .init(
          historyID: history.id, offset: page.start, lines: page.lines, total: history.lines.count,
          subscriptionID: subscription.id, capturedAt: history.capturedAt,
          truncated: history.truncated)))
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
        if let frame = try capture(&subscription) {
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
  private var failures: [String: [TimeInterval]] = [:]

  mutating func allows(source: String, now: TimeInterval) -> Bool {
    guard now.isFinite else { return false }
    prune(now: now)
    return (failures[source]?.count ?? 0) < 12
  }

  mutating func recordFailure(source: String, now: TimeInterval) {
    guard now.isFinite else { return }
    prune(now: now)
    // Bound bookkeeping even when many source addresses fail authentication.
    if failures[source] == nil, failures.count >= 256,
      let oldest = failures.min(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) })?.key
    {
      failures.removeValue(forKey: oldest)
    }
    if (failures[source]?.count ?? 0) < 12 { failures[source, default: []].append(now) }
  }

  private mutating func prune(now: TimeInterval) {
    failures = failures.compactMapValues { times in
      let recent = times.filter { now < $0 + 60 }
      return recent.isEmpty ? nil : recent
    }
  }
}
