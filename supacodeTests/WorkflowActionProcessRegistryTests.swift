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

  @Test func linkedRegistryCannotWriteReadOrRemoveExternalRecords() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let directory = root.appending(path: ".processes")
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
    let executionID = UUID().uuidString
    let victim = outside.appending(path: executionID + ".json")
    let record = WorkflowActionProcessRegistry.Record(
      owner: .init(pid: Int32.max, seconds: 1, microseconds: 0),
      process: .init(pid: Int32.max, seconds: 1, microseconds: 0))
    let data = try JSONEncoder().encode(record)
    try data.write(to: victim)
    var registry = WorkflowActionProcessRegistry(directory: directory)
    registry.processGroup = { $0 }
    #expect(throws: (any Error).self) { try registry.register(executionID: UUID().uuidString, pid: getpid()) }
    #expect(throws: (any Error).self) { try registry.recoverAbandonedProcesses() }
    registry.remove(executionID: executionID)
    #expect(try Data(contentsOf: victim) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == [executionID + ".json"])
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
