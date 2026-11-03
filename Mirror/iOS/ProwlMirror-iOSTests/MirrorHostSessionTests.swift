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
    async let first = session.command(.list(.init()))
    async let second = session.command(.profiles(.init()))
    await waitUntil { channel.commandRequests.count == 2 }
    let ids = channel.commandRequests.map(\.requestID)
    channel.onMessage?(
      .commandResult(.init(commandResponse: .init(requestID: ids[1], response: .object(["n": .number(2)])))))
    channel.onMessage?(
      .commandResult(.init(commandResponse: .init(requestID: ids[0], response: .object(["n": .number(1)])))))
    let (a, b) = try await (first, second)
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

  private func makeSession(_ channel: Channel, clock: any Clock<Duration> = ContinuousClock()) -> MirrorHostSession {
    MirrorHostSession(
      configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: ""), clock: clock,
      makeTransport: { _ in channel })
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

  @MainActor private final class Channel: MirrorTransport {
    var onEnrolled: ((MirrorSavedConnection) -> Void)?
    var onReady: (() -> Void)?
    var onMessage: ((MirrorMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    var verifiedConfiguration: MirrorSavedConnection? { nil }
    var answersReady = true
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
        .panes(.init(panes: [pane], capabilities: ["text-v1", "conversation-v1", "launch-profile"], hostRunID: UUID())))
    }

    func close(_ reason: String?) { closed = true }
  }
}

private nonisolated struct HostTestClock: Clock {
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
