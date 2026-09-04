import ComposableArchitecture
import Foundation

extension AppFeature {
  /// Open the workflow start sheet, or start the run at once when nothing is undecided
  /// (docs-ai 063.011 decisions 2 and 6). `worktreeID` pins an entry's worktree (the Active
  /// Agents menu); nil resolves the action target. `sourceSurfaceID` pre-selects — and for
  /// the Active Agents menu fixes — the "You" row; nil lets the client take the worktree's
  /// focused pane. `forceSheet` is the capsule popover's "Run with Options…" escape hatch.
  func openWorkflowStart(
    state: inout State,
    workflowKey: String,
    worktreeID: Worktree.ID?,
    sourceSurfaceID: UUID?,
    forceSheet: Bool
  ) -> Effect<Action> {
    guard state.workflowStart == nil else { return .none }
    let worktree: Worktree
    if let worktreeID {
      guard let explicitWorktree = state.repositories.terminalWorktree(for: worktreeID) else {
        return .send(
          .repositories(
            .showToast(.warning("The selected worktree is no longer available."))))
      }
      worktree = explicitWorktree
    } else {
      guard let fallbackWorktree = actionTargetWorktree(repositories: state.repositories) else {
        return .none
      }
      worktree = fallbackWorktree
    }
    @Dependency(WorkflowStartClient.self) var workflowStartClient
    guard let context = workflowStartClient.context(workflowKey, worktree.id, sourceSurfaceID)
    else {
      return .send(
        .repositories(
          .showToast(
            .warning("This workflow cannot start — check its file with `prowl workflow validate`")))
      )
    }
    if !forceSheet, context.canStartImmediately {
      // dsl-spec §3 `bind: auto`: no sheet; C1's status center is the start feedback.
      let request = WorkflowStartFeature.State(context: context).request
      return .run { send in
        if case .failed(_, let message) = await workflowStartClient.run(request) {
          await send(.repositories(.showToast(.warning(message))))
        }
      }
    }
    state.workflowStart = WorkflowStartFeature.State(context: context)
    return .none
  }
}

extension AppFeature {
  /// Palette rows come from a state snapshot because the assembler runs on every body
  /// evaluation; the catalog scan happens only when the palette opens.
  func refreshWorkflowPaletteItems(state: inout State) {
    guard let worktree = actionTargetWorktree(repositories: state.repositories) else {
      state.workflowPaletteItems = []
      return
    }
    @Dependency(WorkflowStartClient.self) var workflowStartClient
    state.workflowPaletteItems = workflowStartClient.catalog(worktree.id)
  }
}

extension AppFeature {
  /// The Active Agents rows' `in <workflow> · <role>` subtitles (000-plan entry points),
  /// derived from the live runs' bindings whenever WorkflowRunsFeature state changes.
  func syncWorkflowRoleBadges(state: inout State) {
    let badges = Self.workflowRoleBadges(for: state.workflowRuns)
    if state.repositories.workflowRoleBadgesBySurfaceID != badges {
      state.repositories.workflowRoleBadgesBySurfaceID = badges
    }
  }

  /// Pure derivation (covered by `WorkflowRoleBadgeTests`): every pane bound to an active
  /// run wears `in <workflow> \u{00B7} <role>`.
  static func workflowRoleBadges(for runs: WorkflowRunsFeature.State) -> [UUID: String] {
    var badges: [UUID: String] = [:]
    for session in runs.activeSessions {
      let name = session.run.definition.name
      for (role, binding) in session.run.bindings {
        guard let surfaceID = binding.pane?.surfaceID else { continue }
        badges[surfaceID] = "in \(name) \u{00B7} \(role)"
      }
    }
    return badges
  }
}
