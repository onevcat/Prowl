import Foundation
import Testing

@testable import Prowl

/// The sanitized real transcripts under `Mirror/Fixtures/conversation` must keep producing
/// the committed event files; `PROWL_UPDATE_FIXTURES=1` rewrites them after an adapter change.
struct MirrorConversationFixtureTests {
  private static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Mirror/Fixtures/conversation")

  @Test(arguments: [("claude-review-1038", DetectedAgent.claude), ("codex-review-1038", DetectedAgent.codex)])
  func fixturesMatchTheirGoldenEvents(name: String, agent: DetectedAgent) throws {
    var adapter = try #require(MirrorConversationAdapters.make(for: agent))
    var reader = MirrorJSONLineReader()
    var events: [MirrorConversationEvent] = []
    for line in reader.append(try Data(contentsOf: Self.fixtures.appending(path: "\(name).jsonl"))) {
      let record = try #require(try JSONSerialization.jsonObject(with: line) as? MirrorConversationRecord)
      events += adapter.events(for: record)
    }
    #expect(events.count > 20)
    let consistent = events.allSatisfy(\.isConsistent)
    #expect(consistent)
    var log = MirrorConversationLog()
    log.maximumEvents = 10_000
    log.maximumBytes = 64 * 1024 * 1024
    let assigned = log.append(contentsOf: events)
    #expect(assigned.count == events.count)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let jsonl =
      try assigned.map { event in try #require(String(bytes: encoder.encode(event), encoding: .utf8)) }
      .joined(separator: "\n") + "\n"
    let golden = Self.fixtures.appending(path: "\(name).events.jsonl")
    if ProcessInfo.processInfo.environment["PROWL_UPDATE_FIXTURES"] == "1" {
      try Data(jsonl.utf8).write(to: golden, options: .atomic)
    }
    let expected = try String(contentsOf: golden, encoding: .utf8)
    #expect(jsonl == expected)
    // Every event decodes again with the same encoding: the clients read these files.
    for line in jsonl.split(separator: "\n") {
      let decoded = try JSONDecoder().decode(MirrorConversationEvent.self, from: Data(line.utf8))
      #expect(decoded.isConsistent)
    }
  }
}
