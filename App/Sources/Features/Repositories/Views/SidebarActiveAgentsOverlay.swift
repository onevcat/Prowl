import ComposableArchitecture
import Sharing
import SwiftUI

/// The Active Agents panel plus the `entries → row-display` computation that
/// feeds it, split out of `SidebarListView`.
///
/// `ActiveAgentsFeature.State.entries` is re-emitted whenever an agent's state
/// changes — frequently while agents work. When the read of `entries` lived in
/// `SidebarListView.body`, every such change re-ran the entire sidebar body and
/// recreated every `RepositorySectionView` (measured at ~11 child re-evals per
/// parent re-eval). Isolating the `entries` read here means an entries change
/// re-evaluates only this overlay; the repository list is untouched. See
/// `docs-ai/032-performance-hardening`.
struct SidebarActiveAgentsOverlay: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let panelHeight: Double
  let maximumPanelHeight: Double
  let panelOffset: Double
  let isPanelHidden: Bool
  let sidebarFooterHeight: Double
  let onHeightChanged: (Double) -> Void
  let onHeightChangeEnded: (Double) -> Void

  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.repositoryAppearances) private var repositoryAppearances

  var body: some View {
    let state = store.state
    let metadata = SidebarListView.activeAgentWorktreeMetadata(
      repositories: state.repositories,
      customTitles: state.repositoryCustomTitles,
      repositoryAppearances: repositoryAppearances
    )
    let rowDisplays = SidebarListView.activeAgentRowDisplays(
      entries: state.activeAgents.entries,
      repositories: state.repositories,
      metadata: metadata
    )
    let selectedSurfaceID = state.selectedWorktreeID.flatMap { worktreeID in
      terminalManager.stateIfExists(for: worktreeID)?.activeSurfaceID
    }
    // Only surface the hint while Cmd is held and the bindings are still at their
    // defaults; a customized binding makes the merged "⌥⌃↑↓" glyph inaccurate.
    let shortcutHint =
      commandKeyObserver.isPressed
      ? AppShortcuts.activeAgentsNavigationDisplay(in: resolvedKeybindings)
      : nil

    ActiveAgentsPanel(
      store: store.scope(state: \.activeAgents, action: \.activeAgents),
      rowDisplays: rowDisplays,
      workflowBadges: state.workflowRoleBadgesBySurfaceID,
      selectedSurfaceID: selectedSurfaceID,
      navigationShortcutHint: shortcutHint,
      isCommandKeyPressed: commandKeyObserver.isPressed,
      showTabTitles: state.showActiveAgentTabTitles,
      height: panelHeight,
      maximumHeight: maximumPanelHeight,
      onHeightChanged: onHeightChanged,
      onHeightChangeEnded: onHeightChangeEnded
    )
    .padding(6)
    .frame(height: panelHeight)
    .offset(y: panelOffset)
    .clipped()
    .padding(.bottom, sidebarFooterHeight)
    .allowsHitTesting(!isPanelHidden)
    .animation(.easeOut(duration: 0.18), value: isPanelHidden)
  }
}
