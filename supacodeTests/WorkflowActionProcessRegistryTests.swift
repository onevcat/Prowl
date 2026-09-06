import Darwin
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowActionProcessRegistryTests {
  @Test func recoveryTerminatesOnlyAnAbandonedOwnedGroup() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = WorkflowActionProcessRegistry(directory: directory)
    let executionID = UUID().uuidString
    let ready = AsyncStream<Void>.makeStream()
    let task = Task {
      defer { ready.continuation.finish() }
      return try await WorkflowScriptExecutor.run(
        .init(
          executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"],
          directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"]
        ).limits(timeout: 60),
        request: Data(),
        onSpawn: { pid in
          try registry.register(executionID: executionID, pid: pid)
          ready.continuation.yield()
        })
    }
    defer {
      task.cancel()
      ready.continuation.finish()
    }
    for await _ in ready.stream { break }
    #expect(try registry.recoverAbandonedProcesses() == 0)
    let file = directory.appending(path: executionID + ".json")
    let record = try JSONDecoder().decode(WorkflowActionProcessRegistry.Record.self, from: Data(contentsOf: file))
    let abandoned = WorkflowActionProcessRegistry.Record(
      owner: .init(pid: Int32.max, seconds: 1, microseconds: 0), process: record.process)
    try JSONEncoder().encode(abandoned).write(to: file, options: .atomic)
    try #require(try registry.recoverAbandonedProcesses() == 1)
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func stalePIDIdentityCannotAuthorizeTermination() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = WorkflowActionProcessRegistry.Record(
      owner: .init(pid: Int32.max, seconds: 1, microseconds: 0),
      process: .init(pid: getpid(), seconds: 1, microseconds: 0))
    try JSONEncoder().encode(record).write(to: directory.appending(path: UUID().uuidString + ".json"))
    #expect(try WorkflowActionProcessRegistry(directory: directory).recoverAbandonedProcesses() == 0)
    #expect(kill(getpid(), 0) == 0)
  }
}
