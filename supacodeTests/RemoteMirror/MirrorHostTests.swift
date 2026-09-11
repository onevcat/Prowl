import Foundation
import Network
import Observation
import Testing

@testable import supacode

@MainActor
struct MirrorHostTests {
  @Test func disabledHostNeverStartsOrGeneratesCredentials() {
    let host = MirrorHost(source: Source(), enabled: false)
    host.start()
    #expect(!host.isStarting)
    #expect(!host.isRunning)
    #expect(host.pairingKey.isEmpty)
    #expect(host.hostRunID == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func fullSilentHandshakePoolStillAllowsAuthenticatedSubscription() async throws {
    let source = Source()
    let suite = "MirrorHandshakeTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    host.start()
    var silent: [NWConnection] = []
    defer {
      for connection in silent { connection.cancel() }
      host.stop()
    }
    for await ready in Observations({ host.isRunning || host.error != nil }) where ready { break }
    try #require(host.error == nil)
    for _ in 0..<MirrorHost.maximumPendingHandshakes {
      let connection = NWConnection(
        host: "127.0.0.1", port: .init(rawValue: UInt16(host.port)!)!, using: .tcp)
      silent.append(connection)
      connection.start(queue: .main)
    }
    for await full in Observations({
      host.pendingHandshakeCount == MirrorHost.maximumPendingHandshakes
    }) where full {
      break
    }
    let client = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { client.connection.close() }
    var messages = client.messages.makeAsyncIterator()
    client.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    #expect(await messages.next()?.kind == .subscribed)
    #expect(await messages.next()?.kind == .frame)
    #expect(host.subscriberCount == 1)
    #expect(host.pendingHandshakeCount < MirrorHost.maximumPendingHandshakes)
    host.stop()
    #expect(host.pendingHandshakeCount == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func explicitTakeoverRevokesOldOwnerAndTextReplacesRatherThanAppends() async throws {
    let source = Source()
    let suite = "MirrorTakeoverTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    host.start()
    defer { host.stop() }
    for await ready in Observations({ host.isRunning || host.error != nil }) where ready { break }
    try #require(host.error == nil)
    let first = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let second = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      second.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    first.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let firstLease = try #require(await firstMessages.next()?.subscriptionID)
    #expect(await firstMessages.next()?.kind == .frame)
    second.connection.send(.list)
    let list = try #require(await secondMessages.next())
    #expect(list.hostRunID != nil)
    #expect(source.reads == 1)
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    #expect(await secondMessages.next()?.error?.hasPrefix("PANE_BUSY") == true)
    #expect(source.reads == 1)
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .text, intent: .takeover)))
    let lease = try #require(await secondMessages.next())
    #expect(lease.kind == .subscribed)
    #expect(lease.hostRunID == host.hostRunID)
    let frame = try #require(await secondMessages.next())
    #expect(frame.text == "thinking")
    #expect(frame.subscriptionID == lease.subscriptionID)
    #expect(await firstMessages.next()?.reason == .takenOver)
    #expect(host.subscriberCount == 1)
    source.text = ""
    second.connection.send(
      .acknowledge(
        .init(
          sequence: try #require(frame.sequence), subscriptionID: try #require(lease.subscriptionID)
        )))
    let cleared = try #require(await secondMessages.next())
    #expect(cleared.kind == .textFrame)
    #expect(cleared.text == "")
    // A text mirror may not bypass mobile submit validation with raw input.
    second.connection.send(
      .input(.init(bytes: Data([3]), subscriptionID: try #require(lease.subscriptionID))))
    #expect(await secondMessages.next() == nil)
    #expect(source.input.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func failedTakeoverCaptureKeepsExistingOwner() async throws {
    let source = Source()
    source.textUnavailable = true
    let suite = "MirrorFailedTakeoverTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    host.start()
    defer { host.stop() }
    for await ready in Observations({ host.isRunning || host.error != nil }) where ready { break }
    let first = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let second = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      second.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    first.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let firstLease = try #require(await firstMessages.next()?.subscriptionID)
    #expect(await firstMessages.next()?.kind == .frame)
    second.connection.send(.list)
    _ = await secondMessages.next()
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .text, intent: .takeover)))
    #expect(await secondMessages.next() == nil)
    first.connection.send(.input(.init(bytes: Data([3]), subscriptionID: firstLease)))
    first.connection.send(.history(.init(historyID: nil, offset: nil, subscriptionID: firstLease)))
    #expect(await firstMessages.next()?.kind == .historyPage)
    #expect(source.input == Data([3]))
    #expect(host.subscriberCount == 1)
  }

  @Test(.timeLimit(.minutes(1))) func subscriptionIsExclusiveAndDiscoveryDoesNotReadTerminal()
    async throws
  {
    let source = Source()
    let suite = "MirrorHostTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    host.start()
    defer { host.stop() }
    for await ready in Observations({ host.isRunning || host.error != nil }) where ready {
      break
    }
    try #require(host.error == nil)
    #expect(source.reads == 0)
    let first = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let second = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      second.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    first.connection.send(.list)
    let list = try #require(await firstMessages.next())
    #expect(list.kind == .panes)
    #expect(source.reads == 0)
    first.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let firstLease = try #require(await firstMessages.next()?.subscriptionID)
    let frame = try #require(await firstMessages.next())
    #expect(frame.kind == .frame)
    #expect(host.subscriberCount == 1)
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let failure = try #require(await secondMessages.next())
    #expect(failure.kind == .failure)
    #expect(failure.error?.hasPrefix("PANE_BUSY") == true)
    first.connection.send(.input(.init(bytes: Data([3]), subscriptionID: firstLease)))
    first.connection.send(.history(.init(historyID: nil, offset: nil, subscriptionID: firstLease)))
    let history = try #require(await firstMessages.next())
    #expect(history.kind == .historyPage)
    #expect(source.input == Data([3]))
    #expect(source.reads == 1)
    host.stop()
    #expect(host.subscriberCount == 0)
    #expect(!host.isRunning)
    #expect(source.panes().count == 1)
  }

  @MainActor private final class Source: MirrorPaneSource {
    let id = UUID()
    var reads = 0
    var input = Data()
    var text = "thinking"
    var textUnavailable = false
    func activeText(_ id: UUID) throws -> String {
      if textUnavailable { throw MirrorProtocolError.invalidMessage }
      reads += 1
      return text
    }
    func panes() -> [MirrorPaneDescriptor] {
      [MirrorPaneDescriptor(id: id, title: "Fixture", directory: "/", busy: false)]
    }
    func snapshot(_ id: UUID) throws -> MirrorFrame {
      reads += 1
      return MirrorFrame(columns: 80, rows: 24, bytes: Data("thinking".utf8))
    }
    func write(_ bytes: Data, to id: UUID) throws { input.append(bytes) }
    var supportsBoundedHistory: Bool { true }
    func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
      .init(text: "earlier\nnow", truncated: false)
    }
  }

  private static let identity = MirrorHostIdentity(
    id: UUID(),
    devices: [
      .init(id: UUID(), name: "Test device", key: Data(repeating: 7, count: 32), pairedAt: Date())
    ])

  @MainActor private final class Peer {
    let connection: MirrorConnection
    let messages: AsyncStream<MirrorMessage>
    init(port: UInt16, key: String) async throws {
      let stream = AsyncStream.makeStream(of: MirrorMessage.self)
      let ready = AsyncStream.makeStream(of: Bool.self)
      messages = stream.stream
      let device = MirrorHostTests.identity.devices[0]
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
                  key: device.key, host: challenge.hostID,
                  nonce: challenge.nonce, purpose: "device", identity: device.id.uuidString))))
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
}
