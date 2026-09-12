import Foundation
import Synchronization
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

  @Test func incompleteInventoryDiagnosticsAreThrottledAndReportRecovery() async {
    let messages = Mutex<[String]>([])
    let clock = Mutex<TimeInterval>(0)
    let provider = CodexLogProvider(
      time: { clock.withLock { $0 } }, diagnostic: { message in messages.withLock { $0.append(message) } })
    for _ in 0..<3 { _ = await provider.sample(paths: [], inventoryComplete: false) }
    #expect(messages.withLock { $0.count } == 1)
    clock.withLock { $0 = 30 }
    _ = await provider.sample(paths: [], inventoryComplete: false)
    #expect(messages.withLock { $0.count } == 2)
    _ = await provider.sample(paths: [])
    #expect(messages.withLock { $0.last?.contains("recovered") } == true)
    _ = await provider.sample(paths: [])
    #expect(messages.withLock { $0.count } == 3)
  }

  @Test func resumedMainSourcesRemainEligible() async throws {
    let directory = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    for source in ["cli", "exec", "vscode", "mcp"] {
      let path = directory.appending(path: source + ".jsonl")
      let content = header("a").replacing(#""cli""#, with: "\"" + source + "\"") + start("1")
      try content.write(to: path, atomically: false, encoding: .utf8)
      let provider = CodexLogProvider(startedAt: .distantPast)
      let events = await provider.sample(paths: [path])
      if case .turnStarted("a", "1") = events.last {} else { Issue.record("Unsupported main source: \(source)") }
    }
  }

  @Test func unknownLineageSuspendsWithoutLosingPendingCompletion() async throws {
    let directory = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    for source in ["null", #""unknown""#, #"{"subagent":"review"}"#] {
      let main = directory.appending(path: "main.jsonl")
      let unknown = directory.appending(path: "unknown.jsonl")
      try (header("a") + start("1")).write(to: main, atomically: false, encoding: .utf8)
      try header("u").replacing(#""cli""#, with: source).write(to: unknown, atomically: false, encoding: .utf8)
      let provider = CodexLogProvider(startedAt: .distantPast)
      _ = await provider.sample(paths: [main])
      for _ in 0..<2 {
        let events = await provider.sample(paths: [main, unknown])
        if case .suspended = events.first {} else { Issue.record("Unknown lineage must suspend") }
      }
      #expect(await provider.metadataReadCount == 2)
      try append(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"1"}}"# + "\n", to: main)
      let events = await provider.sample(paths: [main])
      if case .turnEnded("a", "1") = events.last {} else { Issue.record("Completion was lost during suspension") }
    }
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

  @Test func freshMainTurnDoesNotRequireSettingsEvent() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "a.jsonl")
    let metadata = header("a").split(separator: "\n").first!
    try (metadata + "\n" + start("first")).write(to: path, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantPast)
    #expect(await provider.sample(paths: [path]).count == 2)
  }

  @Test func freshChildWithoutForkHistoryDoesNotRequireSettingsEvent() async throws {
    let directory = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let main = directory.appending(path: "main.jsonl")
    let child = directory.appending(path: "child.jsonl")
    try (header("a") + start("a1")).write(to: main, atomically: false, encoding: .utf8)
    let metadata = try #require(header("c", parent: "a").split(separator: "\n").first)
    try (metadata + "\n" + start("c1")).write(to: child, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantPast)
    #expect(await provider.sample(paths: [main, child]).count == 3)
  }

  @Test func forkMetadataKeepsCopiedTurnsBehindTheOwnBoundary() async throws {
    let directory = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let main = directory.appending(path: "main.jsonl")
    let child = directory.appending(path: "child.jsonl")
    try (header("a") + start("a1")).write(to: main, atomically: false, encoding: .utf8)
    let lines = header("c", parent: "a").split(separator: "\n")
    let metadata = String(lines[0]).replacing(#""id":"c""#, with: #""id":"c","forked_from_id":"a""#)
    let content = metadata + "\n" + start("copied") + lines[1] + "\n" + start("own")
    try content.write(to: child, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantPast)
    let events = await provider.sample(paths: [main, child])
    #expect(events.count == 3)
    if case .childStarted(_, _, let work) = events.last {
      #expect(work == "own")
    } else {
      Issue.record("Expected only the child's own live turn")
    }
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
    if case .suspended = orphan.first {} else { Issue.record("Unknown lineage must fall back") }
  }

  @Test func partialNewHeaderDoesNotDiscardExistingCursors() async throws {
    let directory = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let main = directory.appending(path: "main.jsonl")
    let child = directory.appending(path: "child.jsonl")
    try (header("a") + start("a1")).write(to: main, atomically: false, encoding: .utf8)
    let provider = CodexLogProvider(startedAt: .distantPast)
    _ = await provider.sample(paths: [main])
    let childText = header("c", parent: "a") + start("c1")
    try String(childText.prefix(20)).write(to: child, atomically: false, encoding: .utf8)
    _ = await provider.sample(paths: [main, child])
    try append(String(childText.dropFirst(20)), to: child)
    try append(start("a2"), to: main)
    let events = await provider.sample(paths: [main, child])
    #expect(events.count == 3)
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
