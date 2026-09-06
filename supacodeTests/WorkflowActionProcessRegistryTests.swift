import ConcurrencyExtras
import Darwin
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowActionProcessRegistryTests {
  @Test func recoveryTargetsOnlyAnAbandonedOwnedGroup() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let terminated = LockIsolated<[Int32]>([])
    var registry = WorkflowActionProcessRegistry(directory: directory)
    registry.processGroup = { $0 }
    registry.terminateGroup = { pid in
      terminated.withValue { $0.append(pid) }
      return true
    }
    let executionID = UUID().uuidString
    try registry.register(executionID: executionID, pid: getpid())
    #expect(try registry.recoverAbandonedProcesses() == 0)
    #expect(terminated.value.isEmpty)
    let file = directory.appending(path: executionID + ".json")
    let record = try JSONDecoder().decode(WorkflowActionProcessRegistry.Record.self, from: Data(contentsOf: file))
    let abandoned = WorkflowActionProcessRegistry.Record(
      owner: .init(pid: Int32.max, seconds: 1, microseconds: 0), process: record.process)
    try JSONEncoder().encode(abandoned).write(to: file, options: .atomic)
    #expect(try registry.recoverAbandonedProcesses() == 1)
    #expect(terminated.value == [getpid()])
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
