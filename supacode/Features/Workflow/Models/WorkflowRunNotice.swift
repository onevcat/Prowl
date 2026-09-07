import Foundation
import ProwlCLIShared

nonisolated struct WorkflowRunNotice: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case needsAttention
    case completed
    case skipped
    case iterationLimitReached
  }

  let kind: Kind
  let runID: UUID
  let worktreeID: Worktree.ID
  let workflowName: String
  let title: String
  let body: String
  let targetSurfaceID: UUID?
  let postsNotification: Bool

  static func statusEdge(
    from previous: WorkflowRunStatus?,
    to run: WorkflowRun
  ) -> WorkflowRunNotice? {
    guard previous != run.status, previous?.isTerminal != true else { return nil }
    let kind: Kind
    let title: String
    let body: String
    switch run.status {
    case .needsAttention(let attention):
      kind = .needsAttention
      title = "\(run.definition.name) needs attention"
      body = attention.message
    case .completed:
      kind = .completed
      title = "\(run.definition.name) completed"
      body = "Workflow completed in \(run.context.worktree.name)."
    case .skipped(let step, let dependent):
      kind = .skipped
      title = "\(run.definition.name) ended after a skipped step"
      body = "Step '\(step)' was skipped; step '\(dependent)' depended on its output."
    case .iterationLimitReached:
      kind = .iterationLimitReached
      title = "\(run.definition.name) reached its iteration limit"
      body = "The workflow ended after reaching its maximum number of iterations."
    case .running, .cancelled, .interrupted:
      return nil
    }
    return WorkflowRunNotice(
      kind: kind,
      runID: run.id,
      worktreeID: run.context.worktree.id,
      workflowName: run.definition.name,
      title: title,
      body: body,
      targetSurfaceID: targetSurfaceID(for: run),
      postsNotification: true
    )
  }

  static func targetSurfaceID(for run: WorkflowRun) -> UUID? {
    let attentionRole = run.status.attention?.role
    let currentRole = run.definition.roles.first { $0.source == .current }?.name
    return [attentionRole, currentRole, run.currentInvocation?.role]
      .compactMap { $0 }
      .compactMap { run.bindings[$0]?.pane?.surfaceID }
      .first
      ?? run.definition.roles.lazy.compactMap { run.bindings[$0.name]?.pane?.surfaceID }.first
  }
}
