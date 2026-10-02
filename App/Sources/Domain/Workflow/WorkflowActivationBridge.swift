// supacode/Domain/Workflow/WorkflowActivationBridge.swift
// The dispatch-store seam of the run machine's effects (docs-ai 063.007, decision H3). B3
// implements it over `WorktreeTerminalManager` / `AgentDispatchStore`; B2 tests use a fake.
// Trust never comes from here: a delivery is attributed by the caller pane's pending record,
// the token only correlates it with the activation.

import Foundation

/// The outcome of opening a `message` activation on the role's surface (#733's re-dispatch:
/// issue a record and bind it to the pane's current evidence epoch).
nonisolated enum WorkflowActivationOpenFailure: Error, Equatable, Sendable {
  /// The pane already holds a pending record or its agent is working / blocked.
  case roleBusy
  case surfaceMissing
  case capacityExceeded
  case failed(String)

  var injectionFailure: WorkflowInjectionFailure {
    switch self {
    case .roleBusy: .roleBusy
    case .surfaceMissing: .surfaceMissing
    case .capacityExceeded: .activationUnavailable("all dispatch receipt slots are occupied")
    case .failed(let detail): .activationUnavailable(detail)
    }
  }
}

@MainActor
protocol WorkflowActivationBridge: AnyObject {
  /// Issues and binds a pending dispatch record for an agent already running in the pane.
  func openMessageActivation(surfaceID: UUID) -> Result<String, WorkflowActivationOpenFailure>
  /// Rolls back an issuance whose line could not be typed.
  func cancelActivation(dispatchID: String)
  /// Skip / Cancel / Relaunch: the record ends `abandoned` with a reason naming run and step.
  func abandonActivation(dispatchID: String, reason: String)
  /// A validated delivery completes the record with a `succeeded` receipt.
  func completeActivation(dispatchID: String, summary: String)
  /// The epoch-gated observation the watchdog consumes; nil when the record is unknown.
  func observeActivation(dispatchID: String) -> AgentDispatchObservationStream?
}
