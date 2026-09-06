// supacode/Clients/Workflow/WorkflowStartClient.swift
// GUI-side access to workflow starts (docs-ai 063 C2). The live value is assembled in
// WorkflowRuntimeComposition from the same catalog, resolver, settings, and coordinator the
// CLI path uses — the GUI never grows its own run-creation logic (011 decision 1).

import ComposableArchitecture
import Foundation
import ProwlCLIShared

struct WorkflowStartClient: Sendable {
  /// Workflows visible to a worktree, for the entry points. Includes validation-failing files
  /// (the capsule popover dims them); excludes definitions disabled in Settings entirely.
  var catalog: @MainActor @Sendable (_ worktreeID: String) -> [WorkflowStartCatalogItem]
  /// The sheet's raw material for one workflow, or nil when the workflow or worktree is gone.
  var context:
    @MainActor @Sendable (_ workflowKey: String, _ worktreeID: String, _ preferredSourceSurfaceID: UUID?)
      -> WorkflowStartContext?
  /// Submits through the coordinator — the same entry `prowl workflow run` uses.
  var run: @MainActor @Sendable (_ request: WorkflowStartRequest) async -> WorkflowStartOutcome
}

/// The live client is assembled with the app store (`WorkflowStartComposition`) and published
/// here as well: views read this dependency outside any store scope (the Agents popover, the
/// Active Agents context menu), where `@Dependency` resolves the global default rather than
/// the store's installed value.
@MainActor
final class WorkflowStartClientRegistry {
  static let shared = WorkflowStartClientRegistry()
  var client: WorkflowStartClient?
}

extension WorkflowStartClient: DependencyKey {
  static let liveValue = WorkflowStartClient(
    catalog: { WorkflowStartClientRegistry.shared.client?.catalog($0) ?? [] },
    context: { WorkflowStartClientRegistry.shared.client?.context($0, $1, $2) },
    run: {
      await WorkflowStartClientRegistry.shared.client?.run($0)
        ?? .failed(code: CLIErrorCode.transportFailed, message: "Workflow runtime is not available.")
    }
  )

  static let testValue = WorkflowStartClient(
    catalog: { _ in [] },
    context: { _, _, _ in nil },
    run: { _ in .failed(code: CLIErrorCode.transportFailed, message: "No test workflow runtime configured.") }
  )
}

extension DependencyValues {
  var workflowStartClient: WorkflowStartClient {
    get { self[WorkflowStartClient.self] }
    set { self[WorkflowStartClient.self] = newValue }
  }
}
