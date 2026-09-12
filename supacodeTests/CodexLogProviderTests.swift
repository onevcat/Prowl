import Foundation
import Testing

@testable import supacode

struct CodexLogProviderTests {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func header(_ id: String, parent: String? = nil) -> String {
    let source = parent.map { #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#($0)"}}}"# } ?? #""cli""#
    return
      #"{"type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-09-12T00:00:00.000Z","source":\#(source)}}"#
      + "\n"
      + #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"\#(id)"}}"# + "\n"
  }

  private func start(_ turn: String) -> String {
    #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turn)"}}"# + "\n"
  }

  private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  @Test func newlyPersistedFileCanHaveAnOlderSessionTimestamp() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = CodexLogProvider()
    let path = root.appending(path: "a.jsonl")
    try (header("a") + start("first")).write(to: path, atomically: false, encoding: .utf8)
    let events = await provider.sample(paths: [path])
    #expect(events.count == 2)
  }

  @Test func partialLinesAndRepeatedSamplesDoNotDuplicateTurns() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "a.jsonl")
    try (header("a") + String(start("1").dropLast(2))).write(to: path, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantPast)
    #expect(await provider.sample(paths: [path]).count == 1)
    try append("}\n", to: path)
    let events = await provider.sample(paths: [path])
    #expect(events.count == 2)
    #expect(await provider.sample(paths: [path]).count == 1)
  }

  @Test func attachDoesNotReplayHistoricalUnmatchedStart() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "a.jsonl")
    try (header("a") + start("old")).write(to: path, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantFuture)
    #expect(await provider.sample(paths: [path]).count == 1)
    try append(start("new"), to: path)
    let events = await provider.sample(paths: [path])
    if case .turnStarted(_, let turn) = events.last {
      #expect(turn == "new")
    } else {
      Issue.record("Expected only newly appended start")
    }
  }

  @Test func childrenAreOneRootAndUnknownParentFailsClosed() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let main = root.appending(path: "a.jsonl")
    let child = root.appending(path: "c.jsonl")
    try (header("a") + start("a1")).write(to: main, atomically: false, encoding: .utf8)
    try (header("c", parent: "a") + start("c1")).write(to: child, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantPast)
    let events = await provider.sample(paths: [child, main])
    if case .inventory(let roots) = events.first {
      #expect(roots == ["a"])
    } else {
      Issue.record("Expected complete root inventory")
    }
    let orphan = await provider.sample(paths: [child])
    if case .unavailable = orphan.first {} else { Issue.record("Unknown lineage must fall back") }
  }

  @Test func truncationAndMalformedAppendInvalidateWithoutResurrectingHistory() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "a.jsonl")
    try (header("a") + start("old")).write(to: path, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantPast)
    _ = await provider.sample(paths: [path])
    try header("a").write(to: path, atomically: false, encoding: .utf8)
    let events = await provider.sample(paths: [path])
    if case .unavailable = events.first {} else { Issue.record("Truncation must invalidate") }
    #expect(await provider.sample(paths: [path]).count == 1)
    try append("{bad}\n", to: path)
    let malformed = await provider.sample(paths: [path])
    if case .unavailable = malformed.first {} else { Issue.record("Malformed append must invalidate") }
  }
}
