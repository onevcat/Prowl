import Clocks
import Foundation
import Testing

@testable import supacode

@MainActor
struct MirrorCommandChannelTests {
  @Test func unrelatedRepliesDoNotCompleteThePendingCommand() async throws {
    let stream = AsyncStream<MirrorMessage>.makeStream()
    let channel = MirrorCommandChannel(send: { stream.continuation.yield($0) })
    let pending = Task { try await channel.execute(.list(.init())) }
    var sent = stream.stream.makeAsyncIterator()
    let request = try #require(await sent.next()?.commandRequest)
    channel.receive(.init(requestID: UUID(), response: .null))
    #expect(channel.isPending)
    channel.receive(.init(requestID: request.requestID, response: .string("reply")))
    #expect(try await pending.value == .string("reply"))
    #expect(!channel.isPending)
  }

  @Test func timeoutAndCancellationReleaseTheWaiter() async throws {
    let clock = TestClock()
    let stream = AsyncStream<MirrorMessage>.makeStream()
    let channel = MirrorCommandChannel(clock: clock, send: { stream.continuation.yield($0) })
    var sent = stream.stream.makeAsyncIterator()
    let timed = Task { try await channel.execute(.profiles(.init())) }
    _ = await sent.next()
    await clock.advance(by: .seconds(30))
    await #expect(throws: MirrorCommandChannel.Failure.timedOut) { try await timed.value }
    #expect(!channel.isPending)
    let cancelled = Task { try await channel.execute(.profiles(.init())) }
    _ = await sent.next()
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(!channel.isPending)
  }

  @Test func disconnectResolvesPendingCreationWithoutSendingAgain() async throws {
    let stream = AsyncStream<MirrorMessage>.makeStream()
    var count = 0
    let channel = MirrorCommandChannel(send: {
      count += 1
      stream.continuation.yield($0)
    })
    let pending = Task { try await channel.execute(.create(.init(worktreeID: "worktree"))) }
    var sent = stream.stream.makeAsyncIterator()
    _ = await sent.next()
    channel.disconnect()
    await #expect(throws: MirrorCommandChannel.Failure.disconnected) { try await pending.value }
    #expect(count == 1)
  }
}
