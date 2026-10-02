// supacode/Clients/Workflow/WorkflowRuntimeClient.swift
// Terminal-side operations the workflow reducer cannot own (docs-ai 063 B3): the idle wait, the
// typed line, the profile launch, closing a pane, and the user notification. The live values are
// composed in `WorkflowRuntimeComposition.swift`; neither the run machine nor the dispatch store
// learns UI semantics.

import ComposableArchitecture
import Foundation
import ProwlCLIShared

nonisolated enum WorkflowTextDelivery: Equatable, Sendable {
  case delivered
  case insertFailed
  case submitFailed
  /// The liveness guard failed right before insertion: nothing was typed.
  case stale
}

/// How a `message` step's idle wait ended (dsl-spec §10: a `working` role is never injected into).
nonisolated enum WorkflowRoleWaitOutcome: Equatable, Sendable {
  case idle
  /// The role's runtime reported `needs-input`, or its screen stayed blocked for the blocked grace.
  case blocked
  /// The pane is gone.
  case gone
  /// The pane hosts no detected agent; typing into a bare shell would run the line as a command.
  case noAgent
  /// The pane already holds a pending dispatch record (#733 D4: one per surface) that is not
  /// this run's; the record's owner must complete or abandon it first.
  case dispatchPending(String)
  case cancelled
}

nonisolated struct WorkflowLaunchResult: Equatable, Sendable {
  let pane: WorkflowPaneIdentity
  let dispatchID: String?
}

nonisolated enum WorkflowLaunchError: Error, Equatable, Sendable {
  case failed(String)
}

nonisolated struct WorkflowRuntimeNotification: Equatable, Sendable {
  let title: String
  let body: String
  let targetSurfaceID: UUID?
  let workflowRunID: UUID?
  let treatAsViewedWhenWorktreeIsVisible: Bool

  init(
    title: String,
    body: String,
    targetSurfaceID: UUID?,
    treatAsViewedWhenWorktreeIsVisible: Bool = true,
    workflowRunID: UUID? = nil
  ) {
    self.workflowRunID = workflowRunID
    self.title = title
    self.body = body
    self.targetSurfaceID = targetSurfaceID
    self.treatAsViewedWhenWorktreeIsVisible = treatAsViewedWhenWorktreeIsVisible
  }
}

struct WorkflowRuntimeClient: Sendable {
  var observe: @MainActor @Sendable (WorkflowRun) -> [String: WorkflowJSONValue] = { _ in [:] }
  /// The #733 idle precondition without its five-second cap: exact `turn-ended` evidence first,
  /// a stabilized detector view otherwise; returns when the role can receive a line.
  var waitForRole: @MainActor @Sendable (UUID) async -> WorkflowRoleWaitOutcome
  /// `insertCommittedText` + `submitLine` as one operation, entered only if the guard still
  /// holds at that moment (the run's queue fence, checked on the same main-actor turn as the
  /// insertion so a cancel cannot slip in between).
  var deliverLine: @MainActor @Sendable (Worktree, UUID, String, @MainActor () -> Bool) -> WorkflowTextDelivery
  /// Launches the frozen profile plan with the rendered kickoff prompt and the child-only
  /// workflow environment; issues and binds the launch activation when the step expects a delivery.
  var launch:
    @MainActor @Sendable (Worktree, AgentProfileLaunchPlan, WorkflowLaunchRequest) async -> Result<
      WorkflowLaunchResult, WorkflowLaunchError
    >
  /// Closes a `launch` role's pane for the run that launched it, without a confirmation (the
  /// author's `close` step is explicit and the run owns the pane); `false` when the pane is gone
  /// or another active run has bound it since.
  var close: @MainActor @Sendable (Worktree, UUID, UUID) -> Bool
  var notify: @MainActor @Sendable (Worktree, WorkflowRuntimeNotification) -> Void
}

extension WorkflowRuntimeClient: DependencyKey {
  static let liveValue = WorkflowRuntimeClient(
    waitForRole: { _ in .cancelled },
    deliverLine: { _, _, _, _ in .insertFailed },
    launch: { _, _, _ in .failure(.failed("WorkflowRuntimeClient.launch is not configured")) },
    close: { _, _, _ in false },
    notify: { _, _ in }
  )

  static let testValue = WorkflowRuntimeClient(
    waitForRole: { _ in .cancelled },
    deliverLine: { _, _, _, _ in .insertFailed },
    launch: { _, _, _ in .failure(.failed("No test workflow runtime configured.")) },
    close: { _, _, _ in false },
    notify: { _, _ in }
  )
}

extension DependencyValues {
  var workflowRuntimeClient: WorkflowRuntimeClient {
    get { self[WorkflowRuntimeClient.self] }
    set { self[WorkflowRuntimeClient.self] = newValue }
  }
}
