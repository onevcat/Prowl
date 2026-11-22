import Foundation
import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorHostSessionTests {
  @Test(.timeLimit(.minutes(1))) func unansweredHostFailsAfterTheConnectTimeout() async {
    let clock = HostTestClock()
    let channel = Channel()
    channel.answersReady = false
    let session = makeSession(channel, clock: clock)
    session.start()
    #expect(session.status == .connecting)
    #expect(await clock.nextSleep() == MirrorHostSession.connectTimeoutDuration)
    await clock.advance()
    await waitUntil { session.status != .connecting }
    #expect(session.status == .failed("The Host did not answer. Check the address, port and code."))
    #expect(channel.closed)
  }

  @Test func rosterCarriesAgentFieldsAndCapabilities() {
    let channel = Channel()
    let session = makeSession(channel)
    defer { session.stop() }
    session.start()
    #expect(session.status == .ready)
    #expect(session.supportsConversation && session.supportsLaunch)
    #expect(session.panes.first?.agent == "claude")
    #expect(session.panes.first?.agentState == .idle)
    #expect(session.panes.first?.conversation == .pending)
  }

  @Test(.timeLimit(.minutes(1))) func commandsInFlightResolveByRequestID() async throws {
    let channel = Channel()
    let session = makeSession(channel)
    defer { session.stop() }
    session.start()
    async let list = session.command(.list(.init()))
    async let profiles = session.command(.profiles(.init()))
    await waitUntil { channel.commandRequests.count == 2 }
    // The two child tasks reach the Host in either order, so each reply names the command it
    // answers, and the replies arrive in the reverse order of the requests.
    for request in channel.commandRequests.reversed() {
      let answer: Double = request.request.command == .list(.init()) ? 1 : 2
      channel.onMessage?(
        .commandResult(
          .init(commandResponse: .init(requestID: request.requestID, response: .object(["n": .number(answer)])))))
    }
    let (a, b) = try await (list, profiles)
    #expect(a == MirrorJSON.object(["n": .number(1)]))
    #expect(b == MirrorJSON.object(["n": .number(2)]))
  }

  @Test(.timeLimit(.minutes(1))) func connectionLossFailsEveryPendingCommand() async {
    let channel = Channel()
    let session = makeSession(channel)
    defer { session.stop() }
    session.start()
    let pending = Task { try await session.command(.list(.init())) }
    await waitUntil { channel.commandRequests.count == 1 }
    channel.onClose?("gone")
    await #expect(throws: MirrorHostSession.CommandFailure.self) { try await pending.value }
    #expect(session.status == .failed("gone"))
  }

  /// A rejected device key is not tried again by itself: the Host limits rejected attempts for
  /// each address, and a retry loop would shut out the new pairing (found in a live run).
  @Test func aRejectedDeviceKeyIsNotRetriedAutomatically() {
    let channel = Channel()
    let session = makeSession(channel)
    defer { session.stop() }
    session.start()
    #expect(session.retriesAutomatically)
    channel.onClose?("Connection lost.")
    #expect(session.retriesAutomatically)
    session.retry()
    channel.onClose?(MirrorConnection.unrecognizedDevice)
    #expect(session.status == .failed(MirrorConnection.unrecognizedDevice))
    #expect(!session.retriesAutomatically)
  }

  /// The Host can list a pane as busy for a moment after this device closed its mirror of it.
  /// The row must not say "Mirrored elsewhere" about this device; a later roster counts again.
  @Test func aPaneThisDeviceReleasedIsNotBusyInTheNextRosters() throws {
    let channel = Channel()
    let id = UUID()
    channel.listed = [MirrorPaneDescriptor(id: id, title: "Claude", directory: "/repo", busy: true)]
    let session = makeSession(channel)
    defer { session.stop() }
    session.start()
    #expect(session.panes.first?.busy == true)

    let lists = channel.sent.count(where: { $0.kind == .list })
    session.paneReleased(id)
    // The roster it asks for at once may still be stale; so may one more.
    #expect(channel.sent.count(where: { $0.kind == .list }) == lists + 1)
    #expect(session.panes.first?.busy == false)
    session.refresh()
    #expect(session.panes.first?.busy == false)
    // Another device does mirror it: the third roster says so.
    session.refresh()
    #expect(session.panes.first?.busy == true)
  }

  private func makeSession(
    _ channel: Channel, clock: any Clock<Duration> = ContinuousClock(),
    credential: MirrorDeviceCredential? = nil, push: MirrorPushCoordinator = PushCoordinatorWorld().coordinator(enabled: false)
  ) -> MirrorHostSession {
    MirrorHostSession(
      configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: "", credential: credential), clock: clock,
      makeTransport: { _ in channel }, push: push)
  }

  @Test(.timeLimit(.minutes(1))) func registersForPushOncePerConnectionAndKeepsTheHostsAnswer() async {
    let world = PushCoordinatorWorld()
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    let push = world.coordinator()
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let channel = Channel()
    channel.capabilities.append("push-v1")
    let session = makeSession(channel, credential: credential, push: push)
    defer { session.stop() }
    session.start()

    await waitUntil { channel.sent.contains { $0.kind == .pushRegister } }
    session.refresh()
    await waitUntil { channel.sent.filter { $0.kind == .list }.count == 2 }
    #expect(channel.sent.filter { $0.kind == .pushRegister }.count == 1)

    let status = MirrorMessage.PushStatusPayload(pushEnabled: false, pushAllowedByMac: true, registered: true)
    channel.onMessage?(.pushStatus(status))
    #expect(session.status == .ready)
    #expect(push.statuses[credential.hostID] == status)
  }

  @Test(.timeLimit(.minutes(1))) func aTokenTheHostCallsGoneIsReplacedOncePerConnection() async {
    let world = PushCoordinatorWorld()
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    let push = world.coordinator()
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let channel = Channel()
    channel.capabilities.append("push-v1")
    let session = makeSession(channel, credential: credential, push: push)
    defer { session.stop() }
    session.start()
    await waitUntil { channel.sent.contains { $0.kind == .pushRegister } }

    let gone = MirrorMessage.PushStatusPayload(
      pushEnabled: true, pushAllowedByMac: true, registered: false, tokenGone: true)
    channel.onMessage?(.pushStatus(gone))
    await waitUntil { channel.sent.filter { $0.kind == .pushRegister }.count == 2 }
    guard case .pushRegister(let payload) = channel.sent.last(where: { $0.kind == .pushRegister }) else {
      Issue.record("Expected pushRegister")
      return
    }
    // The dead token is forgotten without a deletion, which the gateway would refuse anyway.
    #expect(payload.pushToken == "push-2")
    #expect(world.record(credential.hostID)?.pushToken == "push-2")
    #expect(!world.gateway.routes().contains { $0.hasPrefix("DELETE") })

    // A Host that keeps refusing gets no further attempt on this connection.
    channel.onMessage?(.pushStatus(gone))
    await Task.yield()
    #expect(channel.sent.filter { $0.kind == .pushRegister }.count == 2)
    #expect(world.gateway.routes().filter { $0 == "POST /v1/tokens" }.count == 2)
  }

  @Test(.timeLimit(.minutes(1))) func settingsChangesReachTheConnectedHost() async {
    let world = PushCoordinatorWorld()
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    let push = world.coordinator()
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let channel = Channel()
    channel.capabilities.append("push-v1")
    let session = makeSession(channel, credential: credential, push: push)
    defer { session.stop() }
    session.start()
    await waitUntil { channel.sent.contains { $0.kind == .pushRegister } }

    push.setKinds([.blocked], for: credential.hostID)
    session.pushSettingsChanged()
    await waitUntil { channel.sent.filter { $0.kind == .pushRegister }.count == 2 }
    guard case .pushRegister(let payload) = channel.sent.last(where: { $0.kind == .pushRegister }) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.kinds == ["blocked"])

    push.setEnabled(false)
    session.pushSettingsChanged()
    #expect(channel.sent.last?.kind == .pushUnregister)
  }

  @Test(.timeLimit(.minutes(1))) func aKindChangeReachesTheConnectedAddressOfTheSameMac() async {
    let world = PushCoordinatorWorld()
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    let push = world.coordinator()
    let hostID = UUID()
    let credential = MirrorDeviceCredential(hostID: hostID, deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let channel = Channel()
    channel.capabilities.append("push-v1")
    let connected = MirrorHostRecord(id: UUID(), address: "mac", port: 7880, hostID: hostID, pairedAt: .distantPast)
    let other = MirrorHostRecord(id: UUID(), address: "192.168.1.2", port: 7880, hostID: hostID, pairedAt: .distantPast)
    let sessions = MirrorHostSessions(makeSession: { record in
      MirrorHostSession(
        configuration: .init(
          address: record.address, port: record.port, pairingKey: "",
          credential: record.id == connected.id ? credential : nil),
        makeTransport: { _ in channel }, push: push)
    }, push: push)
    let session = sessions.session(for: connected)
    defer { session.stop() }
    session.start()
    _ = sessions.session(for: other)
    await waitUntil { channel.sent.contains { $0.kind == .pushRegister } }

    sessions.setNotificationKinds([.blocked], for: hostID)
    await waitUntil { channel.sent.filter { $0.kind == .pushRegister }.count == 2 }
    guard case .pushRegister(let payload) = channel.sent.last(where: { $0.kind == .pushRegister }) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.kinds == ["blocked"])
  }

  @Test(.timeLimit(.minutes(1))) func forgettingAPairingDeletesItsTokenAndClosesItsConnection() async {
    let world = PushCoordinatorWorld()
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204, "")
    let push = world.coordinator()
    let hostID = UUID()
    let credential = MirrorDeviceCredential(hostID: hostID, deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let channel = Channel()
    channel.capabilities.append("push-v1")
    let record = MirrorHostRecord(id: UUID(), address: "mac", port: 7880, hostID: hostID, pairedAt: .distantPast)
    let sessions = MirrorHostSessions(
      makeSession: { record in
        MirrorHostSession(
          configuration: .init(address: record.address, port: record.port, pairingKey: "", credential: credential),
          makeTransport: { _ in channel }, push: push)
      }, push: push, deviceID: { _ in credential.deviceID })
    sessions.session(for: record).start()
    await waitUntil { channel.sent.contains { $0.kind == .pushRegister } }

    sessions.forgetPairing(record)
    #expect(channel.closed && sessions.existing(for: record) == nil)
    #expect(await eventually { world.gateway.routes().contains("DELETE /v1/tokens/push-1") })
  }

  @Test func aHostWithoutPushHearsNothingWhenSettingsChange() {
    let world = PushCoordinatorWorld()
    let push = world.coordinator()
    let channel = Channel()
    let session = makeSession(
      channel, credential: MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32)),
      push: push)
    defer { session.stop() }
    session.start()
    push.setEnabled(false)
    session.pushSettingsChanged()
    #expect(!channel.sent.contains { $0.kind == .pushUnregister || $0.kind == .pushRegister })
  }

  @Test func aHostWithoutPushGetsNoRegistration() async {
    let world = PushCoordinatorWorld()
    let channel = Channel()
    let session = makeSession(
      channel, credential: MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32)),
      push: world.coordinator())
    defer { session.stop() }
    session.start()
    await Task.yield()
    #expect(!channel.sent.contains { $0.kind == .pushRegister })
    #expect(world.gateway.requests.isEmpty)
  }

  private func waitUntil(_ predicate: @MainActor () -> Bool) async {
    let changes = AsyncStream.makeStream(of: Void.self)
    defer { changes.continuation.finish() }
    changes.continuation.yield(())
    for await _ in changes.stream {
      let finished = withObservationTracking {
        predicate()
      } onChange: {
        changes.continuation.yield(())
      }
      if finished { break }
    }
  }
}

@MainActor
struct MirrorNotificationOpenerTests {
  private let hostID = UUID()
  private let paneID = UUID()
  private let channel = Channel()
  private let router = MirrorNotificationRouter()
  private let store = MirrorHostStore(
    defaults: UserDefaults(suiteName: "opener-\(UUID().uuidString)")!, adoptsLegacyConnection: false)

  private func sessions() -> MirrorHostSessions {
    MirrorHostSessions(
      makeSession: { [channel] record in
        MirrorHostSession(
          configuration: record.configuration, makeTransport: { _ in channel },
          push: PushCoordinatorWorld().coordinator(enabled: false))
      }, push: PushCoordinatorWorld().coordinator(enabled: false))
  }

  private func listPane() {
    channel.listed = [
      MirrorPaneDescriptor(id: paneID, title: "Claude Code · main", directory: "/repo", busy: false, agent: "claude")
    ]
  }

  @Test(.timeLimit(.minutes(1))) func opensThePaneOnceTheHostListsIt() async {
    listPane()
    let host = store.upsert(address: "mac", port: 7880, hostID: hostID)
    let target = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)
    router.pending = target
    var shown: [MirrorHostRecord] = []
    let outcome = await MirrorNotificationOpener(router: router, store: store, sessions: sessions())
      .open(target) { host in
        shown.append(host)
        store.select(host.id)
      }
    guard case .pane(let route) = outcome else {
      Issue.record("Expected the pane, got \(outcome)")
      return
    }
    #expect(route.pane.id == paneID && route.host == host)
    #expect(shown == [host] && router.pending == nil)
  }

  @Test(.timeLimit(.minutes(1))) func aPaneThatIsGoneLeavesTheAgentsList() async {
    let host = store.upsert(address: "mac", port: 7880, hostID: hostID)
    store.select(host.id)
    let target = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)
    router.pending = target
    let outcome = await MirrorNotificationOpener(router: router, store: store, sessions: sessions()).open(target) { _ in }
    #expect(outcome == .agents && router.pending == nil)
  }

  @Test(.timeLimit(.minutes(1))) func aNewerTapTakesOverWhileConnecting() async {
    listPane()
    channel.answersReady = false
    let host = store.upsert(address: "mac", port: 7880, hostID: hostID)
    store.select(host.id)
    let target = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)
    router.pending = target
    let sessions = sessions()
    let opening = Task { await MirrorNotificationOpener(router: router, store: store, sessions: sessions).open(target) { _ in } }
    await waitUntil { sessions.existing(for: host)?.status == .connecting }
    let newer = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)
    router.pending = newer
    channel.answersReady = true
    channel.onReady?()
    #expect(await opening.value == .unchanged)
    #expect(router.pending == newer)
  }

  @Test func aTapForAnUnknownHostChangesNothing() async {
    _ = store.upsert(address: "mac", port: 7880, hostID: hostID)
    let target = MirrorNotificationRouter.Target(hostID: UUID(), paneID: paneID)
    router.pending = target
    var shown = false
    let outcome = await MirrorNotificationOpener(router: router, store: store, sessions: sessions())
      .open(target) { _ in shown = true }
    #expect(outcome == .unchanged && !shown && router.pending == nil)
  }

  @Test func listsEachMacOnce() {
    let lan = store.upsert(address: "192.168.1.2", port: 7880, hostID: hostID)
    let other = store.upsert(address: "other", port: 7880, hostID: UUID())
    let tailnet = store.upsert(address: "mac.tailnet", port: 7880, hostID: hostID)
    _ = store.upsert(address: "unpaired", port: 7880, hostID: nil)
    let macs = MirrorNotificationsSection.macs(among: store.hosts, selectedID: tailnet.id, isConnected: { _ in false })
    #expect(macs.count == 2 && Set(macs.map(\.host)) == [tailnet, other])
    #expect(MirrorNotificationsSection.macs(among: store.hosts, selectedID: nil, isConnected: { $0 == lan })
      .contains { $0.host == lan })
  }

  private func waitUntil(_ predicate: @MainActor () -> Bool) async {
    let changes = AsyncStream.makeStream(of: Void.self)
    defer { changes.continuation.finish() }
    changes.continuation.yield(())
    for await _ in changes.stream {
      let finished = withObservationTracking { predicate() } onChange: { changes.continuation.yield(()) }
      if finished { break }
    }
  }
}

/// Observable so that `waitUntil` wakes up when a message is sent.
@Observable @MainActor private final class Channel: MirrorTransport {
  var onEnrolled: ((MirrorSavedConnection) -> Void)?
  var onReady: (() -> Void)?
  var onMessage: ((MirrorMessage) -> Void)?
  var onClose: ((String?) -> Void)?
  var verifiedConfiguration: MirrorSavedConnection? { nil }
  var answersReady = true
  /// The panes the Host lists; nil for one idle Claude pane.
  var listed: [MirrorPaneDescriptor]?
  var capabilities = ["text-v1", "conversation-v1", "launch-profile"]
  private(set) var closed = false
  private(set) var sent: [MirrorMessage] = []
  var commandRequests: [MirrorCommandRequest] { sent.compactMap(\.commandRequest) }

  func start() {
    if answersReady { onReady?() }
  }

  func send(_ message: MirrorMessage, closeAfterSending: Bool) {
    sent.append(message)
    guard message.kind == .list else { return }
    let pane = MirrorPaneDescriptor(
      id: UUID(), title: "Claude Code · main", directory: "/repo", busy: false, projectName: "Prowl",
      agent: "claude", agentState: .idle, conversation: .pending)
    onMessage?(
      .panes(
        .init(
          panes: listed ?? [pane], capabilities: capabilities, hostRunID: UUID())))
  }

  func close(_ reason: String?) { closed = true }
}

nonisolated struct HostTestClock: Clock {
  let now = ContinuousClock.now
  let minimumResolution = Duration.zero
  private let storage = Storage()
  func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await storage.sleep(id: id, duration: now.duration(to: deadline))
    } onCancel: {
      Task { await storage.cancel(id) }
    }
  }
  func nextSleep() async -> Duration? { await storage.nextSleep() }
  func advance() async { await storage.advance() }

  private actor Storage {
    let sleeps = AsyncStream.makeStream(of: Duration.self)
    var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var cancelled: Set<UUID> = []
    func sleep(id: UUID, duration: Duration) async throws {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if cancelled.remove(id) != nil {
          continuation.resume(throwing: CancellationError())
        } else {
          pending[id] = continuation
          sleeps.continuation.yield(duration)
        }
      }
    }
    func nextSleep() async -> Duration? {
      var iterator = sleeps.stream.makeAsyncIterator()
      return await iterator.next()
    }
    func advance() {
      let continuations = pending.values
      pending.removeAll()
      for continuation in continuations { continuation.resume() }
    }
    func cancel(_ id: UUID) {
      if let continuation = pending.removeValue(forKey: id) {
        continuation.resume(throwing: CancellationError())
      } else {
        cancelled.insert(id)
      }
    }
  }
}
