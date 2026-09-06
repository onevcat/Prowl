import ComposableArchitecture
import Foundation
import ProwlCLIShared

nonisolated enum WorkflowHistoryStorageKey: DependencyKey {
  static var liveValue: WorkflowHistoryStorage {
    let environment = ProcessInfo.processInfo.environment
    if ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains(where: {
      environment[$0] != nil
    }) {
      return testValue
    }
    if let directory = SupacodePaths.debugDataDirectory {
      return WorkflowHistoryStorage(baseURL: directory.appending(path: "logs/workflow-runs"))
    }
    return .user
  }
  static let testValue = WorkflowHistoryStorage(
    baseURL: FileManager.default.temporaryDirectory.appending(path: "prowl-history-tests-\(UUID().uuidString)"))

}

extension WorkflowHistoryStorage {
  nonisolated static var configured: Self {
    @Dependency(WorkflowHistoryStorageKey.self) var storage
    return storage
  }
}

/// Occupancy outlives a cancelled action until its process transport has completed teardown.
nonisolated final class WorkflowRunOccupancy: @unchecked Sendable, Equatable {
  private let mutex = NSLock()
  private let lock: WorkflowHistoryLock
  private var activities = 0
  private var finished = false

  init(_ lock: WorkflowHistoryLock) { self.lock = lock }
  static func == (lhs: WorkflowRunOccupancy, rhs: WorkflowRunOccupancy) -> Bool { lhs === rhs }

  func beginActivity() {
    mutex.lock()
    defer { mutex.unlock() }
    activities += 1
  }

  func endActivity() {
    mutex.lock()
    defer { mutex.unlock() }
    activities -= 1
    if finished && activities == 0 { lock.close() }
  }

  func finish() {
    mutex.lock()
    defer { mutex.unlock() }
    finished = true
    if activities == 0 { lock.close() }
  }
}
