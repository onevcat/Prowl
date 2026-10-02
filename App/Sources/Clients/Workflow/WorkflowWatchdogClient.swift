// supacode/Clients/Workflow/WorkflowWatchdogClient.swift
// Arms B2's `WorkflowWatchdog` driver for one waiting activation (docs-ai 063 B3, decision H6).
// The driver lives inside the reducer effect that consumes its verdicts, so cancelling that
// effect (`disarmWatchdog`, run teardown) tears the streams and deadlines down with it.

import ComposableArchitecture
import Foundation

struct WorkflowWatchdogHandle: Sendable {
  let verdicts: AsyncStream<WorkflowWatchdogVerdict>
  let cancel: @MainActor @Sendable () -> Void
}

struct WorkflowWatchdogClient: Sendable {
  var arm: @MainActor @Sendable (UUID, WorkflowWatchdogRequest) -> WorkflowWatchdogHandle
}

extension WorkflowWatchdogClient: DependencyKey {
  static let liveValue = WorkflowWatchdogClient(
    arm: { _, _ in WorkflowWatchdogHandle(verdicts: AsyncStream { $0.finish() }, cancel: {}) }
  )

  static let testValue = liveValue
}

extension DependencyValues {
  var workflowWatchdogClient: WorkflowWatchdogClient {
    get { self[WorkflowWatchdogClient.self] }
    set { self[WorkflowWatchdogClient.self] = newValue }
  }
}
