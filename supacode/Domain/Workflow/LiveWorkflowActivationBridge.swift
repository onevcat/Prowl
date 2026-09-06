import Foundation
import ProwlCLIShared

/// Production adapter for B2 activation effects. It resolves the exact live surface at issuance
/// time, then delegates all lifecycle ownership to the existing dispatch store.
@MainActor
final class LiveWorkflowActivationBridge: WorkflowActivationBridge {
  typealias ResolveTarget = @MainActor (UUID) -> TabResolvedTarget?

  private let terminalManager: WorktreeTerminalManager
  private let resolveTarget: ResolveTarget

  init(terminalManager: WorktreeTerminalManager, resolveTarget: @escaping ResolveTarget) {
    self.terminalManager = terminalManager
    self.resolveTarget = resolveTarget
  }

  func openMessageActivation(surfaceID: UUID) -> Result<String, WorkflowActivationOpenFailure> {
    guard let target = resolveTarget(surfaceID) else { return .failure(.surfaceMissing) }
    do {
      return .success(try terminalManager.issueAgentDispatch(boundTo: target).record.id)
    } catch let error as AgentDispatchStoreError {
      return .failure(Self.openFailure(for: error))
    } catch {
      return .failure(.failed("\(error)"))
    }
  }

  func cancelActivation(dispatchID: String) {
    terminalManager.cancelAgentDispatchIssuance(dispatchID: dispatchID)
  }

  func abandonActivation(dispatchID: String, reason: String) {
    do {
      _ = try terminalManager.abandonAgentDispatch(dispatchID: dispatchID, reason: reason)
    } catch {
      appLogger.warning("[Workflow] Could not abandon activation \(dispatchID): \(error)")
    }
  }

  func completeActivation(dispatchID: String, summary: String) {
    guard let snapshot = terminalManager.agentDispatchSnapshot(dispatchID: dispatchID),
      let surfaceID = snapshot.binding?.surfaceID
    else {
      appLogger.warning("[Workflow] Could not complete unbound activation \(dispatchID).")
      return
    }
    do {
      _ = try terminalManager.completeAgentDispatch(
        dispatchID: dispatchID, outcome: .succeeded, summary: summary, callerSurfaceID: surfaceID)
    } catch {
      appLogger.warning("[Workflow] Could not complete activation \(dispatchID): \(error)")
    }
  }

  func observeActivation(dispatchID: String) -> AgentDispatchObservationStream? {
    try? terminalManager.observeAgentDispatch(dispatchID: dispatchID)
  }

  private static func openFailure(for error: AgentDispatchStoreError) -> WorkflowActivationOpenFailure {
    switch error {
    case .surfacePending: .roleBusy
    case .capacityExceeded: .capacityExceeded
    case .bindingMissing, .notFound: .surfaceMissing
    case .alreadyBound, .sourceMismatch, .alreadyCompleted, .alreadyTerminal: .failed("\(error)")
    }
  }
}
