import Foundation
import Network
import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorNativeTransportTests {
  @Test(.timeLimit(.minutes(1))) func nativeTLSCarriesReplacementText() async throws {
    let parameters = try MirrorConnection.parameters(pairingKey: "ABCD2345")
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let ready = AsyncStream.makeStream(of: NWEndpoint.Port.self)
    listener.stateUpdateHandler = { state in
      if case .ready = state, let port = listener.port { ready.continuation.yield(port) }
      if case .failed = state { ready.continuation.finish() }
    }
    var server: MirrorConnection?
    let lease = UUID()
    listener.newConnectionHandler = { connection in
      Task { @MainActor in
        let peer = MirrorConnection(connection)
        server = peer
        peer.onMessage = { message in
          if message.kind == .list {
            peer.send(.textFrame(.init(sequence: 1, text: "思考中\nSwift", subscriptionID: lease)))
          }
        }
        peer.start()
      }
    }
    listener.start(queue: .main)
    defer {
      listener.cancel()
      server?.close()
      ready.continuation.finish()
    }
    var ports = ready.stream.makeAsyncIterator()
    let port = try #require(await ports.next())
    let peer = MirrorConnection(
      NWConnection(
        host: "127.0.0.1", port: port,
        using: try MirrorConnection.parameters(pairingKey: "ABCD2345")))
    let received = AsyncStream.makeStream(of: MirrorMessage.self)
    peer.onReady = { peer.send(.list) }
    peer.onMessage = { received.continuation.yield($0) }
    peer.onClose = { _ in received.continuation.finish() }
    peer.start()
    defer {
      peer.close()
      received.continuation.finish()
    }
    var messages = received.stream.makeAsyncIterator()
    let frame = try #require(await messages.next())
    #expect(frame.text == "思考中\nSwift")
    #expect(frame.subscriptionID == lease)
  }
}
