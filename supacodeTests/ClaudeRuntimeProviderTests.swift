import Foundation
import Synchronization
import Testing

@testable import supacode

struct ClaudeRuntimeProviderTests {
  private let session = "d5afa682-cb4a-4d23-95a0-16a4bb621be6"
  private let start = Date(timeIntervalSince1970: 1_789_402_075.4)

  private func record(status: String = "idle", pid: Int = 42) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "pid": pid, "sessionId": session, "cwd": "/tmp/experiment", "kind": "interactive",
      "pidDomain": "darwin", "procStart": "Mon Sep 14 16:07:55 2026", "status": status,
      "updatedAt": 1_789_402_087_000, "statusUpdatedAt": 1_789_402_087_000,
    ])
  }

  @Test func nativeStatesIncludeBackgroundShellWork() throws {
    for (raw, expected) in [
      ("busy", AgentRawState.working), ("shell", .working), ("waiting", .blocked), ("idle", .idle),
    ] {
      let snapshot = try ClaudeRuntimeDecoder.decode(
        record(status: raw), process: AgentProcessGeneration(pid: 42, startedAt: start))
      #expect(snapshot.state == expected)
      #expect(snapshot.sessionID == session)
    }
  }

  @Test func wrongGenerationUnknownStateAndPartialRecordsFailClosed() throws {
    let process = AgentProcessGeneration(pid: 42, startedAt: start)
    for data in [try record(pid: 43), try record(status: "future-state"), Data("{".utf8), Data("{}".utf8)] {
      #expect(throws: (any Error).self) { try ClaudeRuntimeDecoder.decode(data, process: process) }
    }
    #expect(throws: (any Error).self) {
      try ClaudeRuntimeDecoder.decode(
        record(), process: AgentProcessGeneration(pid: 42, startedAt: start.addingTimeInterval(2)))
    }
  }

  @Test func identityAndSizeBoundariesRejectUnsupportedRecords() throws {
    let process = AgentProcessGeneration(pid: 42, startedAt: start)
    for (key, value) in [
      ("sessionId", "../../other"), ("kind", "background"), ("pidDomain", "linux"), ("cwd", "relative"),
    ] {
      var object = try #require(JSONSerialization.jsonObject(with: record()) as? [String: Any])
      object[key] = value
      let data = try JSONSerialization.data(withJSONObject: object)
      #expect(throws: (any Error).self) { try ClaudeRuntimeDecoder.decode(data, process: process) }
    }
    #expect(throws: (any Error).self) {
      try ClaudeRuntimeDecoder.decode(Data(repeating: 32, count: 65_537), process: process)
    }
  }

  @Test func processReplacementDuringReadCannotPublishSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
    try record().write(to: root.appending(path: "sessions/42.json"))
    let calls = Mutex(0)
    let provider = ClaudeRuntimeProvider(
      processStart: { _ in
        calls.withLock { count in
          count += 1
          return count == 1 ? self.start : self.start.addingTimeInterval(10)
        }
      }, diagnostic: { _ in })
    let result = await provider.sample(process: AgentProcessGeneration(pid: 42, startedAt: start), configRoot: root)
    guard case .unavailable = result.last else {
      Issue.record("Published replaced process")
      return
    }
  }

  @Test func olderAtomicReplacementSuspendsInsteadOfRewindingState() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
    let path = root.appending(path: "sessions/42.json")
    let process = AgentProcessGeneration(pid: 42, startedAt: start)
    let provider = ClaudeRuntimeProvider(processStart: { _ in self.start }, diagnostic: { _ in })
    try record().write(to: path, options: .atomic)
    _ = await provider.sample(process: process, configRoot: root)
    var object = try #require(JSONSerialization.jsonObject(with: record(status: "busy")) as? [String: Any])
    object["updatedAt"] = 1_789_402_086_000
    object["statusUpdatedAt"] = 1_789_402_086_000
    try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
    guard case .suspended = await provider.sample(process: process, configRoot: root).last else {
      Issue.record("Replayed an older snapshot")
      return
    }
  }

  @Test func registryRecoversWithoutLogWritesAndRejectsDeadProcess() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
    let path = root.appending(path: "sessions/42.json")
    let process = AgentProcessGeneration(pid: 42, startedAt: start)
    let provider = ClaudeRuntimeProvider(processStart: { _ in self.start }, diagnostic: { _ in })
    #expect(await provider.sample(process: process, configRoot: root).isEmpty == false)
    try record(status: "busy").write(to: path)
    let events = await provider.sample(process: process, configRoot: root)
    guard case .native(let snapshot) = events.last else {
      Issue.record("Missing native snapshot")
      return
    }
    #expect(snapshot.state == .working)
    try Data("{".utf8).write(to: path)
    _ = await provider.sample(process: process, configRoot: root)
    try record().write(to: path)
    guard case .native(let recovered) = await provider.sample(process: process, configRoot: root).last else {
      Issue.record("Did not recover")
      return
    }
    #expect(recovered.state == .idle)
    let dead = ClaudeRuntimeProvider(processStart: { _ in nil }, diagnostic: { _ in })
    guard case .unavailable = await dead.sample(process: process, configRoot: root).last else {
      Issue.record("Dead PID retained authority")
      return
    }
  }
}
