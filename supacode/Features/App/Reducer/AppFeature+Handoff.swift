import ComposableArchitecture
import Foundation
import Sharing

extension AppFeature {
  /// Open the hand-off HUD for the selected runnable target. Requires a
  /// detected agent on the selected pane — the no-source mechanical handoff
  /// stays CLI-only (docs-ai 049).
  func openHandoffHud(state: inout State) -> Effect<Action> {
    guard state.handoffHud == nil else { return .none }
    guard let worktree = state.repositories.selectedTerminalWorktree else { return .none }
    let source = terminalClient.handoffSourceContext(worktree.id)
    guard let hudState = makeHandoffHudState(worktree: worktree, source: source) else {
      return .send(.repositories(.showToast(.warning("No agent detected in the current pane"))))
    }
    state.handoffHud = hudState
    return .none
  }

  /// Open the hand-off HUD for a specific Active Agents entry (context menu).
  /// The source is captured from the entry's own pane, so it works regardless
  /// of which pane currently holds focus; RepositoriesFeature selects and
  /// focuses the entry's worktree from the same action.
  func openHandoffHud(state: inout State, entryID: ActiveAgentEntry.ID) -> Effect<Action> {
    guard state.handoffHud == nil else { return .none }
    guard let entry = state.repositories.activeAgents.entries[id: entryID],
      let worktree = state.repositories.terminalWorktree(for: entry.worktreeID)
    else { return .none }
    let source = terminalClient.handoffSourceContextForSurface(entry.worktreeID, entry.surfaceID)
    guard let hudState = makeHandoffHudState(worktree: worktree, source: source) else {
      return .send(.repositories(.showToast(.warning("No agent detected in this pane"))))
    }
    state.handoffHud = hudState
    return .none
  }

  private func makeHandoffHudState(
    worktree: Worktree,
    source: HandoffSourceContext?
  ) -> HandoffHudFeature.State? {
    @Shared(.userGlobalSettings) var globalSettings
    @Shared(.userRepositorySettings(worktree.repositoryRootURL)) var repositorySettings
    return HandoffHudFeature.State.make(
      worktree: worktree,
      source: source,
      profiles: globalSettings.agentProfiles,
      designatedProfileID: repositorySettings.defaultAgentProfileID,
      lastLaunchedProfileID: repositorySettings.lastLaunchedAgentProfileID
    )
  }
}
