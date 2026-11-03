import Foundation
import Network
import Observation
import Testing

@testable import Prowl

/// `conversation-v1` over the real loopback Host: snapshot, acknowledged batches, resume by
/// sequence, representation switches, and transcript changes (docs-ai 087).
@MainActor
struct MirrorHostConversationTests {
  @Test(.timeLimit(.minutes(1))) func replaysThenStreamsOneBatchAtATime() async throws {
    let fixture = try await Fixture(transcript: [Self.claudeUser("hello")])
    defer { fixture.tearDown() }
    let lease = try await fixture.subscribeConversation()
    let replay = try await fixture.collect(until: .userMessage, lease: lease)
    #expect(replay.map(\.kind).contains(.agentStatus))
    #expect(replay.map(\.kind).contains(.sessionStarted))
    #expect(replay.map(\.sequence) == replay.map(\.sequence).sorted())
    #expect(fixture.host.subscriberCount == 1)

    try fixture.append(Self.claudeUser("two"))
    let second = try #require(await fixture.next())
    #expect(second.kind == .conversationEvents)
    let texts = (second.conversationEvents ?? []).compactMap { event -> String? in
      if case .message(let message) = event.payload { return message.text.text }
      return nil
    }
    #expect(texts == ["two"])
    // Without an acknowledgement the Host holds the next batch; it arrives after the ack.
    try fixture.append(Self.claudeUser("three"))
    fixture.acknowledge(second, lease: lease)
    let third = try #require(await fixture.next())
    #expect(third.kind == .conversationEvents)
    let later = (third.conversationEvents ?? []).compactMap { event -> String? in
      if case .message(let message) = event.payload { return message.text.text }
      return nil
    }
    #expect(later == ["three"])
    #expect((third.sequence ?? 0) > (second.sequence ?? 0))
  }

  @Test(.timeLimit(.minutes(1))) func wrongAcknowledgementClosesTheConnection() async throws {
    let fixture = try await Fixture(transcript: [Self.claudeUser("hello")])
    defer { fixture.tearDown() }
    let lease = try await fixture.subscribeConversation()
    _ = try await fixture.collect(until: .userMessage, lease: lease)
    try fixture.append(Self.claudeUser("two"))
    let batch = try #require(await fixture.next())
    fixture.peer.connection.send(.acknowledge(.init(sequence: (batch.sequence ?? 0) + 5, subscriptionID: lease)))
    #expect(await fixture.next() == nil)
  }

  @Test(.timeLimit(.minutes(1))) func unsupportedPaneFailsWithoutClosingAndTextStillWorks() async throws {
    let fixture = try await Fixture(transcript: [], agent: nil)
    defer { fixture.tearDown() }
    fixture.peer.connection.send(
      .subscribe(.init(paneID: fixture.source.id, representation: .conversation, intent: .ifFree)))
    let failure = try #require(await fixture.next())
    #expect(failure.kind == .failure && failure.error?.hasPrefix("CONVERSATION_UNSUPPORTED") == true)
    #expect(fixture.host.subscriberCount == 0)
    fixture.peer.connection.send(.subscribe(.init(paneID: fixture.source.id, representation: .text, intent: .ifFree)))
    #expect(await fixture.next()?.kind == .subscribed)
    #expect(await fixture.next()?.kind == .textFrame)
  }

  @Test(.timeLimit(.minutes(1))) func sameConnectionSwitchesRepresentationAndKeepsSequences() async throws {
    let fixture = try await Fixture(transcript: [Self.claudeUser("hello")])
    defer { fixture.tearDown() }
    fixture.peer.connection.send(.subscribe(.init(paneID: fixture.source.id, representation: .text, intent: .ifFree)))
    #expect(await fixture.next()?.kind == .subscribed)
    #expect(await fixture.next()?.kind == .textFrame)
    let lease = try await fixture.subscribeConversation()
    let replay = try await fixture.collect(until: .userMessage, lease: lease)
    #expect(fixture.host.subscriberCount == 1)
    let latest = try #require(replay.last?.sequence)
    fixture.peer.connection.send(.subscribe(.init(paneID: fixture.source.id, representation: .text, intent: .ifFree)))
    #expect(await fixture.next()?.kind == .subscribed)
    #expect(await fixture.next()?.kind == .textFrame)
    // Back to the conversation: the feed survived, so `since` resumes after the known sequence.
    fixture.peer.connection.send(
      .subscribe(
        .init(paneID: fixture.source.id, representation: .conversation, intent: .ifFree, since: latest)))
    #expect(await fixture.next()?.kind == .subscribed)
    let snapshot = try #require(await fixture.next())
    #expect(snapshot.kind == .conversationSnapshot && snapshot.gap == false)
    #expect((snapshot.conversationEvents ?? []).allSatisfy { $0.sequence > latest })
  }

  @Test(.timeLimit(.minutes(1))) func reconnectResumesBySequenceFromTheRetainedFeed() async throws {
    let fixture = try await Fixture(transcript: [Self.claudeUser("hello")])
    defer { fixture.tearDown() }
    let lease = try await fixture.subscribeConversation()
    let replay = try await fixture.collect(until: .userMessage, lease: lease)
    let latest = try #require(replay.last?.sequence)
    fixture.peer.connection.close()
    try fixture.append(Self.claudeUser("after"))
    let again = try await Fixture.Peer(port: fixture.port, key: fixture.host.pairingKey)
    defer { again.connection.close() }
    var messages = again.messages.makeAsyncIterator()
    again.connection.send(
      .subscribe(
        .init(paneID: fixture.source.id, representation: .conversation, intent: .ifFree, since: latest)))
    #expect(await messages.next()?.kind == .subscribed)
    var received: [MirrorConversationEvent] = []
    while !received.contains(where: { event in
      if case .message(let message) = event.payload { return message.text.text == "after" }
      return false
    }) {
      let message = try #require(await messages.next())
      #expect(message.kind == .conversationSnapshot || message.kind == .conversationEvents)
      #expect(message.gap != true)
      received += message.conversationEvents ?? []
      if let sequence = message.sequence, !(message.conversationEvents ?? []).isEmpty {
        again.connection.send(.acknowledge(.init(sequence: sequence, subscriptionID: message.subscriptionID!)))
      }
    }
    #expect(received.allSatisfy { $0.sequence > latest })
    #expect(!received.map(\.kind).contains(.sessionStarted))
  }

  @Test(.timeLimit(.minutes(1))) func transcriptChangeAnnouncesANewSession() async throws {
    let fixture = try await Fixture(transcript: [Self.claudeUser("hello")])
    defer { fixture.tearDown() }
    let lease = try await fixture.subscribeConversation()
    _ = try await fixture.collect(until: .userMessage, lease: lease)
    let second = try Fixture.temporaryTranscript([Self.claudeUser("fresh", session: "s2")])
    defer { try? FileManager.default.removeItem(at: second) }
    fixture.source.setTranscript(second)
    let events = try await fixture.collect(until: .userMessage, lease: lease)
    let kinds = events.map(\.kind)
    #expect(kinds.contains(.sessionChanged) && kinds.contains(.sessionStarted))
    let sessionIDs = events.compactMap { event -> String? in
      if case .session(let session) = event.payload { return session.id }
      return nil
    }
    #expect(sessionIDs.contains("s2"))
  }

  @Test(.timeLimit(.minutes(1))) func statusChangesBecomeEvents() async throws {
    let fixture = try await Fixture(transcript: [Self.claudeUser("hello")])
    defer { fixture.tearDown() }
    let lease = try await fixture.subscribeConversation()
    _ = try await fixture.collect(until: .userMessage, lease: lease)
    fixture.source.setState(.blocked, reason: .programStatus(.blocked(.permission)))
    let events = try await fixture.collect(until: .agentStatus, lease: lease)
    guard case .status(let status) = try #require(events.last(where: { $0.kind == .agentStatus })).payload else {
      Issue.record("expected a status payload")
      return
    }
    #expect(status.state == .blocked && status.kind == "permission")
  }

  @Test func paneDescriptorsCarryAgentAndConversationSupport() {
    let claude = PaneAgentState(
      detectedAgent: .claude, session: .init(id: "s", transcriptPath: URL(filePath: "/tmp/x.jsonl"), source: .commandLine),
      state: .working)
    #expect(GhosttyMirrorPaneSource.conversationSupport(claude) == .available)
    #expect(GhosttyMirrorPaneSource.conversationSupport(PaneAgentState(detectedAgent: .codex, state: .idle)) == .pending)
    #expect(GhosttyMirrorPaneSource.conversationSupport(PaneAgentState(detectedAgent: .gemini, state: .idle)) == .unsupported)
    #expect(GhosttyMirrorPaneSource.conversationSupport(nil) == .unsupported)
  }

  // MARK: - Fixture

  static func claudeUser(_ text: String, session: String = "s1") -> String {
    #"{"type":"user","sessionId":"\#(session)","cwd":"/repo","timestamp":"2026-11-03T14:18:56.620Z","#
      + #""promptId":"p","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#
  }

  @MainActor final class Source: MirrorPaneSource {
    let id = UUID()
    private(set) var state: PaneAgentState?
    func panes() -> [MirrorPaneDescriptor] { [MirrorPaneDescriptor(id: id, title: "Fixture", directory: "/", busy: false)] }
    func snapshot(_ id: UUID) throws -> MirrorFrame { MirrorFrame(columns: 80, rows: 24, bytes: Data("x".utf8)) }
    func write(_ bytes: Data, to id: UUID) throws {}
    func activeText(_ id: UUID) throws -> String { "shell" }
    func agentState(_ id: UUID) -> PaneAgentState? { state }

    func setAgent(_ agent: DetectedAgent?, transcript: URL?) {
      guard let agent else {
        state = nil
        return
      }
      state = PaneAgentState(
        detectedAgent: agent,
        session: transcript.map { .init(id: "s", transcriptPath: $0, source: .commandLine, confidence: .exact) },
        state: .working)
    }

    func setTranscript(_ url: URL) {
      state?.session = .init(id: "s2", transcriptPath: url, source: .commandLine, confidence: .exact)
    }

    func setState(_ raw: AgentRawState, reason: AgentStateDecisionReason) {
      state?.state = raw
      state?.decision = .init(state: raw, reason: reason)
    }
  }

  private static let identity = MirrorHostIdentity(
    id: UUID(),
    devices: [
      .init(id: UUID(), name: "Test device", key: Data(repeating: 9, count: 32), pairedAt: Date())
    ])

  @MainActor final class Peer {
    let connection: MirrorConnection
    let messages: AsyncStream<MirrorMessage>
    init(port: UInt16, key: String) async throws {
      let stream = AsyncStream.makeStream(of: MirrorMessage.self)
      let ready = AsyncStream.makeStream(of: Bool.self)
      messages = stream.stream
      let device = MirrorHostConversationTests.identity.devices[0]
      let peer = MirrorConnection(
        NWConnection(
          host: "127.0.0.1", port: .init(rawValue: port)!,
          using: try MirrorConnection.parameters(keys: [(device.id.uuidString, device.key)])))
      connection = peer
      peer.onMessage = { message in
        switch message {
        case .challenge(let challenge):
          peer.send(
            .authenticate(
              .init(
                deviceID: device.id,
                proof: MirrorAuthentication.proof(
                  key: device.key, host: challenge.hostID, nonce: challenge.nonce, purpose: "device",
                  identity: device.id.uuidString))))
        case .authenticated: ready.continuation.yield(true)
        default: stream.continuation.yield(message)
        }
      }
      peer.onClose = { _ in
        ready.continuation.yield(false)
        stream.continuation.finish()
      }
      peer.start()
      var readiness = ready.stream.makeAsyncIterator()
      try #require(await readiness.next() == true)
      ready.continuation.finish()
    }
  }

  @MainActor final class Fixture {
    let source = Source()
    let host: MirrorHost
    let port: UInt16
    let peer: Peer
    let transcript: URL
    private let suite: String
    private let defaults: UserDefaults
    private var iterator: AsyncStream<MirrorMessage>.AsyncIterator

    init(transcript lines: [String], agent: DetectedAgent? = .claude) async throws {
      transcript = try Self.temporaryTranscript(lines)
      source.setAgent(agent, transcript: transcript)
      suite = "MirrorHostConversationTests-\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      host = MirrorHost(
        source: source, defaults: defaults, enabled: true, loadIdentity: { MirrorHostConversationTests.identity },
        saveIdentity: { _ in })
      host.address = "127.0.0.1"
      host.port = String(try MirrorTestPort.unusedPort())
      try await MirrorTestPort.startHost(host)
      port = UInt16(host.port)!
      peer = try await Peer(port: port, key: host.pairingKey)
      iterator = peer.messages.makeAsyncIterator()
    }

    func tearDown() {
      peer.connection.close()
      host.stop()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: transcript)
    }

    static func temporaryTranscript(_ lines: [String]) throws -> URL {
      let url = FileManager.default.temporaryDirectory.appending(path: "mirror-host-\(UUID().uuidString).jsonl")
      try Data((lines.map { $0 + "\n" }).joined().utf8).write(to: url)
      return url
    }

    func append(_ line: String) throws {
      let handle = try FileHandle(forWritingTo: transcript)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((line + "\n").utf8))
      try handle.close()
    }

    func next() async -> MirrorMessage? { await iterator.next() }

    func subscribeConversation() async throws -> UUID {
      peer.connection.send(.subscribe(.init(paneID: source.id, representation: .conversation, intent: .ifFree)))
      let subscribed = try #require(await next())
      #expect(subscribed.kind == .subscribed)
      return try #require(subscribed.subscriptionID)
    }

    func acknowledge(_ message: MirrorMessage, lease: UUID) {
      guard let sequence = message.sequence, !(message.conversationEvents ?? []).isEmpty else { return }
      peer.connection.send(.acknowledge(.init(sequence: sequence, subscriptionID: lease)))
    }

    /// Reads snapshot and event batches, acknowledging each, until `kind` has been seen.
    func collect(until kind: MirrorConversationEvent.Kind, lease: UUID) async throws -> [MirrorConversationEvent] {
      var received: [MirrorConversationEvent] = []
      while !received.contains(where: { $0.kind == kind }) {
        let message = try #require(await next())
        #expect(message.kind == .conversationSnapshot || message.kind == .conversationEvents)
        #expect(message.subscriptionID == lease)
        received += message.conversationEvents ?? []
        acknowledge(message, lease: lease)
      }
      return received
    }
  }
}
