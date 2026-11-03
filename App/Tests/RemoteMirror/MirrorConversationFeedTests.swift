import Foundation
import Testing

@testable import Prowl

@MainActor
struct MirrorConversationFeedTests {
  private func temporaryFile(_ lines: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mirror-feed-\(UUID().uuidString).jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    return url
  }

  private func claudeUser(_ text: String, session: String = "s1") -> String {
    #"{"type":"user","sessionId":"\#(session)","cwd":"/repo","timestamp":"2026-11-03T14:18:56.620Z","#
      + #""promptId":"p","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#
  }

  private func codexMeta(_ id: String) -> String {
    #"{"type":"session_meta","timestamp":"2026-11-03T04:33:40.707Z","#
      + #""payload":{"id":"\#(id)","cwd":"/repo","cli_version":"0.166.0"}}"#
  }

  private func codexMessage(_ text: String) -> String {
    #"{"type":"event_msg","timestamp":"2026-11-03T04:33:41.701Z","payload":{"type":"item_completed","#
      + #""item":{"type":"AgentMessage","id":"m","phase":"final_answer","#
      + #""content":[{"type":"Text","text":"\#(text)"}]}}}"#
  }

  private func makeFeed(replayLimit: Int = 1 << 20) -> MirrorConversationFeed {
    MirrorConversationFeed(
      queue: DispatchQueue(label: "feed-test"),
      tailOptions: .init(replayLimitBytes: replayLimit, pollInterval: .milliseconds(50)))
  }

  private func appendLine(_ line: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + "\n").utf8))
    try handle.close()
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
    try appendLine(claudeUser("again"), to: url)
    await waitUntil { feed.log.latestSequence >= 5 }
    #expect(feed.log.events.map(\.kind) == [.sessionStarted, .turnStarted, .userMessage, .turnStarted, .userMessage])
    #expect(delivered.map(\.sequence) == [1, 2, 3, 4, 5])
    #expect(feed.log.snapshot(since: 3).events.map(\.sequence) == [4, 5])
    feed.stop()
  }

  @Test func switchingTranscriptsAnnouncesTheChangeAndRestatesStatus() async throws {
    let first = try temporaryFile([claudeUser("one")])
    let second = try temporaryFile([claudeUser("two", session: "s2")])
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    let feed = makeFeed()
    feed.observe(PaneAgentState(detectedAgent: .claude, state: .working))
    feed.follow(.init(url: first, agent: .claude))
    await waitUntil { feed.log.latestSequence >= 4 }
    #expect(feed.log.events.map(\.kind) == [.agentStatus, .sessionStarted, .turnStarted, .userMessage])
    feed.follow(.init(url: second, agent: .claude), reason: .clear)
    await waitUntil { feed.log.events.count >= 5 }
    #expect(
      feed.log.events.map(\.kind) == [.sessionChanged, .agentStatus, .sessionStarted, .turnStarted, .userMessage])
    // The status observed before the first follow took sequence 1 and left with that segment.
    #expect(feed.log.events.first?.sequence == 6)
    #expect(feed.log.snapshot(since: 2).gap)
    guard case .session(let changed) = feed.log.events[0].payload,
      case .session(let started) = feed.log.events[2].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(changed.reason == .clear && started.id == "s2")
    // The same unchanged pane reports nothing new in the segment.
    feed.observe(PaneAgentState(detectedAgent: .claude, state: .working))
    #expect(feed.log.events.count == 5)
    feed.follow(nil, reason: .new)
    #expect(feed.log.events.map(\.kind) == [.sessionPending, .agentStatus])
    feed.follow(.init(url: second, agent: .gemini))
    #expect(feed.log.events.map(\.kind) == [.sessionPending, .agentStatus] && feed.transcript == nil)
    let before = feed.log.latestSequence
    feed.follow(.init(url: second, agent: .gemini))
    #expect(feed.log.latestSequence == before)
    feed.stop()
  }

  @Test func rotationStartsANewSegment() async throws {
    let url = try temporaryFile([claudeUser("one")])
    defer { try? FileManager.default.removeItem(at: url) }
    let feed = makeFeed()
    feed.observe(PaneAgentState(detectedAgent: .claude, state: .idle))
    feed.follow(.init(url: url, agent: .claude))
    await waitUntil { feed.log.latestSequence >= 4 }
    let oldLatest = feed.log.latestSequence
    try FileManager.default.removeItem(at: url)
    try Data((claudeUser("fresh", session: "s2") + "\n").utf8).write(to: url, options: .atomic)
    await waitUntil(timeout: .seconds(5)) {
      feed.log.events.contains { event in
        if case .session(let session) = event.payload { return session.id == "s2" }
        return false
      }
    }
    let kinds = feed.log.events.map(\.kind)
    // A delete event seen before the replacement exists adds a `session.pending` segment first.
    #expect(kinds.first == .sessionChanged || kinds.first == .sessionPending)
    #expect(kinds.contains(.agentStatus) && kinds.contains(.sessionStarted))
    #expect(
      !feed.log.events.contains { event in
        if case .message(let message) = event.payload { return message.text.text == "one" }
        return false
      })
    #expect(feed.log.snapshot(since: oldLatest - 1).gap)
    #expect(feed.log.snapshot(since: nil).gap == false)
    feed.stop()
  }

  @Test func boundedCodexReplayStillAnnouncesTheSession() async throws {
    var lines = [codexMeta("thread-7")]
    lines += (1...40).map { codexMessage("message \($0)") }
    let url = try temporaryFile(lines)
    defer { try? FileManager.default.removeItem(at: url) }
    let feed = makeFeed(replayLimit: 600)
    feed.follow(.init(url: url, agent: .codex))
    await waitUntil { feed.log.events.contains { $0.kind == .assistantMessage } }
    #expect(feed.log.events.first?.kind == .sessionStarted)
    guard case .session(let session) = feed.log.events[0].payload else {
      Issue.record("expected a session payload")
      return
    }
    #expect(session.id == "thread-7")
    #expect(feed.log.events.filter { $0.kind == .assistantMessage }.count < 40)
    feed.stop()
  }

  @Test func unreadableRecordsBecomeOneNotice() async throws {
    let url = try temporaryFile(["not json", "{\"half\"", claudeUser("ok")])
    defer { try? FileManager.default.removeItem(at: url) }
    let feed = makeFeed()
    feed.follow(.init(url: url, agent: .claude))
    await waitUntil { feed.log.events.contains { $0.kind == .userMessage } }
    #expect(feed.log.events.filter { $0.kind == .notice }.count == 1)
    feed.stop()
  }

  @Test func replayOffsetInsideTheHeaderStillAnnouncesTheSession() async throws {
    let padding = String(repeating: "x", count: 400)
    let header =
      #"{"type":"session_meta","timestamp":"2026-11-03T04:33:40.707Z","#
      + #""payload":{"id":"thread-8","cwd":"/repo","cli_version":"0.166.0","base_instructions":"\#(padding)"}}"#
    let lines = [header] + (1...5).map { codexMessage("message \($0)") }
    let url = try temporaryFile(lines)
    defer { try? FileManager.default.removeItem(at: url) }
    let size = try #require(
      FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int)
    // The window starts 50 bytes into the header record.
    let feed = makeFeed(replayLimit: size - 50)
    feed.follow(.init(url: url, agent: .codex))
    await waitUntil { feed.log.events.contains { $0.kind == .assistantMessage } }
    #expect(feed.log.events.first?.kind == .sessionStarted)
    #expect(feed.log.snapshot(since: nil).session?.id == "thread-8")
    #expect(feed.log.events.filter { $0.kind == .assistantMessage }.count == 5)
    feed.stop()
  }

  @Test func aLongReplayKeepsTheSessionForFreshSubscribers() async throws {
    let lines = [codexMeta("thread-9")] + (1...600).map { codexMessage("message \($0)") }
    let url = try temporaryFile(lines)
    defer { try? FileManager.default.removeItem(at: url) }
    let feed = makeFeed()
    feed.follow(.init(url: url, agent: .codex))
    await waitUntil { feed.log.latestSequence >= 601 }
    let snapshot = feed.log.snapshot(since: nil)
    #expect(snapshot.gap && snapshot.events.first?.kind != .sessionStarted)
    #expect(snapshot.session?.id == "thread-9")
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
