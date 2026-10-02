// supacode/Clients/Workflow/WorkflowCLIResponderClient.swift
// The reducer's side of the CLI rendezvous (docs-ai 063 B3, decision W1): a `done` request is
// answered when its activation leaves `persisting`, never on the `.deliveryPersisted` event alone;
// a self-initiated `run` is answered once its first activation is open. The composition root
// turns the resolution into a wire response and resumes the socket handler.

import ComposableArchitecture
import Foundation

/// How a CLI request that entered the reducer ended.
nonisolated enum WorkflowRequestResolution: Equatable, Sendable {
  /// A self-initiated run whose first activation is now open (or whose opening failed and left
  /// the run in attention): the caller can act on the returned line.
  case started(run: WorkflowRun)
  /// The output is the step's output and the run advanced.
  case delivered(run: WorkflowRun, receipt: WorkflowDeliveryReceipt)
  /// The output is on disk with issues; the run waits for the user (decision H14).
  case provisional(run: WorkflowRun, receipt: WorkflowDeliveryReceipt)
  case failed(code: String, message: String)
}

struct WorkflowCLIResponderClient: Sendable {
  var respond: @MainActor @Sendable (UUID, WorkflowRequestResolution) -> Void
}

extension WorkflowCLIResponderClient: DependencyKey {
  static let liveValue = WorkflowCLIResponderClient(respond: { _, _ in })
  static let testValue = liveValue
}

extension DependencyValues {
  var workflowCLIResponder: WorkflowCLIResponderClient {
    get { self[WorkflowCLIResponderClient.self] }
    set { self[WorkflowCLIResponderClient.self] = newValue }
  }
}
