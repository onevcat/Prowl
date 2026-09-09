import Foundation
import Network
import Observation
import Testing

@testable import supacode

@MainActor
struct MirrorHostTests {
  @Test(.timeLimit(.minutes(1))) func subscriptionIsExclusiveAndDiscoveryDoesNotReadTerminal() async throws {
    let source = Source()
    let suite = "MirrorHostTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(source: source, defaults: defaults)
    host.address = "127.0.0.1"
    host.port = String(UInt16.random(in: 49152...65535))
    host.start()
    defer { host.stop() }
    for await ready in Observations({ host.isRunning || host.error != nil }) where ready {
      break
    }
    #expect(host.error == nil)
    #expect(source.reads == 0)
    let first = try Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let second = try Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      second.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    first.connection.send(MirrorMessage(kind: .list))
    let list = try #require(await firstMessages.next())
    #expect(list.kind == .panes)
    #expect(source.reads == 0)
    first.connection.send(MirrorMessage(kind: .subscribe, paneID: source.id))
    let frame = try #require(await firstMessages.next())
    #expect(frame.kind == .frame)
    #expect(host.subscriberCount == 1)
    second.connection.send(MirrorMessage(kind: .subscribe, paneID: source.id))
    let failure = try #require(await secondMessages.next())
    #expect(failure.kind == .failure)
    #expect(failure.error?.hasPrefix("PANE_BUSY") == true)
    first.connection.send(MirrorMessage(kind: .input, bytes: Data([3])))
    first.connection.send(MirrorMessage(kind: .history))
    let history = try #require(await firstMessages.next())
    #expect(history.kind == .historyPage)
    #expect(source.input == Data([3]))
    #expect(source.reads == 1)
    host.stop()
    #expect(host.subscriberCount == 0)
    #expect(!host.isRunning)
    #expect(source.panes().count == 1)
  }

  @Test(.timeLimit(.minutes(1))) func wrongPairingKeyCannotReadMetadata() async throws {
    let listener = try NWListener(using: MirrorConnection.parameters(pairingKey: String(repeating: "a", count: 64)))
    let accepted = AsyncStream.makeStream(of: Bool.self)
    var server: MirrorConnection?
    listener.newConnectionHandler = { connection in
      Task { @MainActor in
        server = MirrorConnection(connection)
        server?.onReady = { server?.send(MirrorMessage(kind: .panes, panes: [])) }
        server?.start()
      }
    }
    listener.stateUpdateHandler = { state in
      if case .ready = state { accepted.continuation.yield(true) }
    }
    listener.start(queue: .main)
    defer {
      server?.close()
      listener.cancel()
      accepted.continuation.finish()
    }
    var readiness = accepted.stream.makeAsyncIterator()
    _ = await readiness.next()
    let peer = try Peer(port: try #require(listener.port).rawValue, key: String(repeating: "b", count: 64))
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    #expect(await messages.next() == nil)
  }

  @MainActor private final class Source: MirrorPaneSource {
    let id = UUID()
    var reads = 0
    var input = Data()
    func panes() -> [MirrorPaneDescriptor] {
      [MirrorPaneDescriptor(id: id, title: "Fixture", directory: "/", busy: false)]
    }
    func snapshot(_ id: UUID) throws -> MirrorFrame {
      reads += 1
      return MirrorFrame(columns: 80, rows: 24, bytes: Data("thinking".utf8))
    }
    func write(_ bytes: Data, to id: UUID) throws { input.append(bytes) }
    func retainedText(_ id: UUID) throws -> String { "earlier\nnow" }
  }

  @MainActor private final class Peer {
    let connection: MirrorConnection
    let messages: AsyncStream<MirrorMessage>
    init(port: UInt16, key: String) throws {
      let stream = AsyncStream.makeStream(of: MirrorMessage.self)
      messages = stream.stream
      connection = MirrorConnection(
        NWConnection(
          host: "127.0.0.1", port: .init(rawValue: port)!,
          using: try MirrorConnection.parameters(pairingKey: key)))
      connection.onMessage = { stream.continuation.yield($0) }
      connection.onClose = { _ in stream.continuation.finish() }
      connection.start()
    }
  }
}
