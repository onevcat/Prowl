import Clocks
import Foundation
import Network
import Testing

@testable import supacode

@MainActor
struct MirrorConnectionTests {
  @Test(.timeLimit(.minutes(1))) func silentPeerTimesOutDespiteOutgoingHeartbeats() async throws {
    let listener = try NWListener(using: .tcp)
    let listening = AsyncStream<Void>.makeStream()
    var server: NWConnection?
    listener.newConnectionHandler = { connection in
      Task { @MainActor in
        server = connection
        connection.start(queue: .main)
      }
    }
    listener.stateUpdateHandler = { state in
      if case .ready = state { listening.continuation.yield(()) }
    }
    listener.start(queue: .main)
    defer {
      server?.cancel()
      listener.cancel()
      listening.continuation.finish()
    }
    var readyListener = listening.stream.makeAsyncIterator()
    _ = await readyListener.next()
    let clock = TestClock()
    let peer = MirrorConnection(
      NWConnection(host: "127.0.0.1", port: try #require(listener.port), using: .tcp), clock: clock)
    let ready = AsyncStream<Void>.makeStream()
    let closed = AsyncStream<String?>.makeStream()
    var closeCount = 0
    peer.onReady = { ready.continuation.yield(()) }
    peer.onClose = {
      closeCount += 1
      closed.continuation.yield($0)
    }
    defer {
      peer.close()
      ready.continuation.finish()
      closed.continuation.finish()
    }
    peer.start()
    var readyPeer = ready.stream.makeAsyncIterator()
    _ = await readyPeer.next()
    await clock.advance(by: .seconds(7))
    #expect(closeCount == 0)
    await clock.advance(by: .seconds(1))
    var closure = closed.stream.makeAsyncIterator()
    let reason = await closure.next()
    #expect(reason??.contains("timed out") == true)
    #expect(closeCount == 1)
    peer.close()
    #expect(closeCount == 1)
  }
}
