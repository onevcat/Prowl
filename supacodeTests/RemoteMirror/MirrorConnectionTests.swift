import Clocks
import Foundation
import Network
import Testing

@testable import supacode

@MainActor
struct MirrorConnectionTests {
  @Test func staleInputCannotInterruptQueuedEndMessage() {
    let peer = MirrorConnection(
      NWConnection(host: "127.0.0.1", port: 1, using: .tcp), clock: TestClock())
    defer { peer.close() }
    var inputDelivered = false
    var closed = false
    peer.onMessage = { _ in
      inputDelivered = true
      // Host has already removed this lease before queuing its ended response.
      peer.close("Invalid subscription.")
    }
    peer.onClose = { _ in closed = true }
    // An unstarted transport holds its send completion. Deliver an already-decoded
    // input before yielding to model an in-flight message during final-send drain.
    peer.send(.ended(.init(reason: .takenOver)), closeAfterSending: true)
    peer.receive(.input(.init(bytes: Data([65]), subscriptionID: UUID())))
    #expect(!inputDelivered)
    #expect(!closed)
  }

  @Test func activeConnectionDispatchesInput() {
    let peer = MirrorConnection(
      NWConnection(host: "127.0.0.1", port: 1, using: .tcp), clock: TestClock())
    defer { peer.close() }
    let input = MirrorMessage.input(.init(bytes: Data([65]), subscriptionID: UUID()))
    var received: MirrorMessage?
    peer.onMessage = { received = $0 }
    peer.receive(input)
    #expect(received?.kind == .input)
    #expect(received?.bytes == input.bytes)
    #expect(received?.subscriptionID == input.subscriptionID)
  }

  @Test(.timeLimit(.minutes(1))) func incompleteHandshakeUsesShortDeadlineWithoutCountingFailure()
    async throws
  {
    let listener = try NWListener(using: .tcp)
    let listening = AsyncStream<Void>.makeStream()
    let accepted = AsyncStream<NWConnection>.makeStream()
    listener.newConnectionHandler = { connection in
      connection.start(queue: .main)
      accepted.continuation.yield(connection)
    }
    listener.stateUpdateHandler = { state in
      if case .ready = state { listening.continuation.yield(()) }
    }
    listener.start(queue: .main)
    defer {
      listener.cancel()
      listening.continuation.finish()
      accepted.continuation.finish()
    }
    var readyListener = listening.stream.makeAsyncIterator()
    _ = await readyListener.next()
    let clock = TestClock()
    let peer = MirrorConnection(
      NWConnection(
        host: "127.0.0.1", port: try #require(listener.port),
        using: try MirrorConnection.parameters(pairingKey: MirrorPairingCode.generate())),
      clock: clock, handshakeTimeout: .seconds(5))
    var closeReason: String?
    var failedHandshake = false
    peer.onClose = { closeReason = $0 }
    peer.onHandshakeFailure = { failedHandshake = true }
    defer { peer.close() }
    peer.start()
    var serverAccepted = accepted.stream.makeAsyncIterator()
    let server = try #require(await serverAccepted.next())
    defer { server.cancel() }
    await clock.advance(by: .seconds(4))
    #expect(closeReason == nil)
    await clock.advance(by: .seconds(1))
    #expect(closeReason?.contains("timed out") == true)
    #expect(!failedHandshake)
  }

  @Test(.timeLimit(.minutes(1))) func refusedConnectionFailsBeforeTheHandshakeDeadline() async throws {
    try await MirrorTestPort.withRefusedPort { port in
      let clock = TestClock()
      let peer = MirrorConnection(
        NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp), clock: clock)
      let closed = AsyncStream<String?>.makeStream()
      var failedHandshake = false
      peer.onClose = { closed.continuation.yield($0) }
      peer.onHandshakeFailure = { failedHandshake = true }
      defer {
        peer.close()
        closed.continuation.finish()
      }
      peer.start()
      var reasons = closed.stream.makeAsyncIterator()
      // The clock never advances: only the waiting state can end this connection.
      let reason = await reasons.next()
      #expect(reason != nil)
      #expect(peer.failure == .refused)
      #expect(failedHandshake)
    }
  }

  @Test(.timeLimit(.minutes(1))) func silentPeerTimesOutDespiteOutgoingHeartbeats() async throws {
    let listener = try NWListener(using: .tcp)
    let listening = AsyncStream<Void>.makeStream()
    let accepted = AsyncStream<NWConnection>.makeStream()
    listener.newConnectionHandler = { connection in
      connection.start(queue: .main)
      accepted.continuation.yield(connection)
    }
    listener.stateUpdateHandler = { state in
      if case .ready = state { listening.continuation.yield(()) }
    }
    listener.start(queue: .main)
    defer {
      listener.cancel()
      listening.continuation.finish()
      accepted.continuation.finish()
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
    var serverAccepted = accepted.stream.makeAsyncIterator()
    let server = try #require(await serverAccepted.next())
    defer { server.cancel() }
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
