import Foundation
import Testing

@testable import Prowl

struct MirrorConversationLogTests {
  private func notice(_ text: String) -> MirrorConversationEvent {
    .init(.notice, .notice(.init(level: .info, text: text)), at: nil, source: .host)
  }

  @Test func assignsSequencesAndReplaysSince() {
    var log = MirrorConversationLog()
    let assigned = log.append(contentsOf: [notice("a"), notice("b"), notice("c")])
    #expect(assigned.map(\.sequence) == [1, 2, 3])
    #expect(log.latestSequence == 3)
    let all = log.snapshot(since: nil)
    #expect(all.events.map(\.sequence) == [1, 2, 3] && !all.gap && all.latestSequence == 3)
    let tail = log.snapshot(since: 1)
    #expect(tail.events.map(\.sequence) == [2, 3] && !tail.gap)
    let current = log.snapshot(since: 3)
    #expect(current.events.isEmpty && !current.gap)
    let future = log.snapshot(since: 9)
    #expect(future.events.isEmpty && !future.gap)
  }

  @Test func evictsByCountAndReportsGaps() {
    var log = MirrorConversationLog()
    log.maximumEvents = 3
    log.append(contentsOf: (1...5).map { notice("\($0)") })
    #expect(log.events.map(\.sequence) == [3, 4, 5])
    let fromStart = log.snapshot(since: nil)
    #expect(fromStart.gap && fromStart.events.map(\.sequence) == [3, 4, 5])
    let beforeOldest = log.snapshot(since: 1)
    #expect(beforeOldest.gap && beforeOldest.events.map(\.sequence) == [3, 4, 5])
    let atOldest = log.snapshot(since: 2)
    #expect(!atOldest.gap && atOldest.events.map(\.sequence) == [3, 4, 5])
  }

  @Test func evictsByBytesButKeepsTheNewestEvent() {
    var log = MirrorConversationLog()
    log.maximumBytes = 600
    log.append(contentsOf: [notice(String(repeating: "x", count: 300)), notice(String(repeating: "y", count: 300))])
    #expect(log.events.map(\.sequence) == [2])
    log.append(notice(String(repeating: "z", count: 2000)))
    #expect(log.events.map(\.sequence) == [3])
  }

  @Test func clearKeepsCountingAndStartsAFreshSegment() {
    var log = MirrorConversationLog()
    log.append(contentsOf: [notice("a"), notice("b")])
    log.clear()
    #expect(log.events.isEmpty && log.latestSequence == 2)
    let empty = log.snapshot(since: nil)
    #expect(empty.events.isEmpty && !empty.gap && empty.latestSequence == 2)
    let next = log.append(notice("c"))
    #expect(next.sequence == 3)
    let fresh = log.snapshot(since: nil)
    #expect(!fresh.gap && fresh.events.map(\.sequence) == [3])
    let stale = log.snapshot(since: 1)
    #expect(stale.gap && stale.events.map(\.sequence) == [3])
  }
}
