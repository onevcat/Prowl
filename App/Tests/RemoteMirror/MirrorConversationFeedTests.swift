import Foundation
import Testing

@testable import Prowl

struct MirrorConversationStatusMapperTests {
  @Test func emitsOnlyChangesWithKindAndSource() {
    var mapper = MirrorConversationStatusMapper()
    var pane = PaneAgentState(detectedAgent: .claude, state: .working)
    pane.decision = .init(state: .working, reason: .programStatus(.working))
    let working = mapper.event(for: pane, at: Date())
    #expect(working?.kind == .agentStatus && working?.source == .osc)
    #expect(mapper.event(for: pane, at: Date()) == nil)
    pane.state = .blocked
    pane.decision = .init(state: .blocked, reason: .programStatus(.blocked(.permission)))
    guard case .status(let blocked) = mapper.event(for: pane, at: Date())?.payload else {
      Issue.record("expected a status event")
      return
    }
    #expect(blocked.state == .blocked && blocked.kind == "permission" && blocked.reason == "osc.blocked.permission")
    pane.decision = .init(state: .blocked, reason: .screen(.noRuleMatched))
    guard let screen = mapper.event(for: pane, at: Date()), case .status(let fromScreen) = screen.payload else {
      Issue.record("expected a status event")
      return
    }
    #expect(screen.source == .screen && fromScreen.kind == "unspecified")
    #expect(mapper.event(for: PaneAgentState(state: .working), at: Date()) == nil)
  }
}

@MainActor
struct MirrorConversationFeedTests {
  private func temporaryFile(_ lines: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mirror-feed-\(UUID().uuidString).jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    return url
  }

  private func claudeUser(_ text: String, session: String = "s1") -> String {
    #"{"type":"user","sessionId":"\#(session)","cwd":"/repo","timestamp":"2026-11-03T14:18:56.620Z","#
      + #""promptId":"p","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#
  }

  private func makeFeed() -> MirrorConversationFeed {
    MirrorConversationFeed(
      queue: DispatchQueue(label: "feed-test"),
      tailOptions: .init(replayLimitBytes: 1 << 20, pollInterval: .milliseconds(50)))
  }

  @Test func replaysThenAppendsWithSequences() async throws {
    let url = try temporaryFile([claudeUser("hello")])
    defer { try? FileManager.default.removeItem(at: url) }
    let feed = makeFeed()
    var delivered: [MirrorConversationEvent] = []
    feed.onEvents = { delivered += $0 }
    feed.follow(.init(url: url, agent: .claude))
    await waitUntil { feed.log.latestSequence >= 3 }
    #expect(feed.log.events.map(\.kind) == [.sessionStarted, .turnStarted, .userMessage])
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((claudeUser("again") + "\n").utf8))
    try handle.close()
    await waitUntil { feed.log.latestSequence >= 5 }
    #expect(feed.log.events.map(\.kind) == [.sessionStarted, .turnStarted, .userMessage, .turnStarted, .userMessage])
    #expect(delivered.map(\.sequence) == [1, 2, 3, 4, 5])
    #expect(feed.log.snapshot(since: 3).events.map(\.sequence) == [4, 5])
    feed.stop()
  }

  @Test func switchingTranscriptsAnnouncesTheChangeAndClearsTheLog() async throws {
    let first = try temporaryFile([claudeUser("one")])
    let second = try temporaryFile([claudeUser("two", session: "s2")])
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let feed = makeFeed()
    feed.follow(.init(url: first, agent: .claude))
    await waitUntil { feed.log.latestSequence >= 3 }
    feed.follow(.init(url: second, agent: .claude), reason: .clear)
    await waitUntil { feed.log.events.count >= 4 }
    #expect(feed.log.events.map(\.kind) == [.sessionChanged, .sessionStarted, .turnStarted, .userMessage])
    #expect(feed.log.events.first?.sequence == 4)
    guard case .session(let changed) = feed.log.events[0].payload,
      case .session(let started) = feed.log.events[1].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(changed.reason == .clear && started.id == "s2")
    feed.follow(nil, reason: .new)
    #expect(feed.log.events.map(\.kind) == [.sessionPending])
    feed.follow(.init(url: second, agent: .gemini))
    #expect(feed.log.events.map(\.kind) == [.sessionPending] && feed.transcript == nil)
    feed.stop()
  }

  @Test func observesAgentStatusChanges() {
    let feed = makeFeed()
    var pane = PaneAgentState(detectedAgent: .codex, state: .working)
    feed.observe(pane)
    feed.observe(pane)
    pane.state = .idle
    feed.observe(pane)
    #expect(feed.log.events.map(\.kind) == [.agentStatus, .agentStatus])
    feed.stop()
  }
}
