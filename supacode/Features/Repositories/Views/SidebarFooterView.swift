import ComposableArchitecture
import SwiftUI

struct SidebarFooterView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(\.surfaceBottomChromeBackgroundOpacity) private var surfaceBottomChromeBackgroundOpacity
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openURL) private var openURL
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @Environment(AskAgentHelpPresenter.self) private var askAgentHelp

  var body: some View {
    HStack {
      Menu {
        Button("Ask Agent About Prowl", systemImage: "sparkles") {
          askAgentHelp.present()
        }
        .help("Copy a prompt that points your AI agent at Prowl's bundled docs")
        Divider()
        Button("Homepage", systemImage: "house") {
          if let url = URL(string: "https://prowl.onev.cat/") {
            openURL(url)
          }
        }
        .help("Open Prowl homepage")
        Button("Release Notes", systemImage: "note.text") {
          if let url = URL(string: "https://prowl.onev.cat/releases/") {
            openURL(url)
          }
        }
        .help("View release notes")
        Divider()
        Button("Submit GitHub Issue", systemImage: "exclamationmark.bubble") {
          if let url = URL(string: "https://github.com/onevcat/supacode/issues/new") {
            openURL(url)
          }
        }
        .help("Submit GitHub issue")
      } label: {
        Label("Help", systemImage: "questionmark.circle")
          .labelStyle(.iconOnly)
      }
      .menuIndicator(.hidden)
      .help("Help")
      Spacer()
      Button {
        withAnimation(.easeOut(duration: 0.18)) {
          _ = store.send(.activeAgents(.togglePanelVisibility))
        }
      } label: {
        Image(systemName: Self.activeAgentsPanelIconName(isPanelHidden: store.state.activeAgents.isPanelHidden))
          .accessibilityLabel(store.state.activeAgents.isPanelHidden ? "Show Active Agents" : "Hide Active Agents")
      }
      .help(
        AppShortcuts.helpText(
          title: store.state.activeAgents.isPanelHidden ? "Show Active Agents" : "Hide Active Agents",
          commandID: AppShortcuts.CommandID.toggleActiveAgentsPanel,
          in: resolvedKeybindings
        )
      )
      Button {
        store.send(.refreshWorktrees)
      } label: {
        Image(systemName: "arrow.clockwise")
          .symbolEffect(.rotate, options: .repeating, isActive: store.state.isRefreshingWorktrees)
          .accessibilityLabel("Refresh Worktrees")
      }
      .help(
        AppShortcuts.helpText(
          title: "Refresh Worktrees",
          commandID: AppShortcuts.CommandID.refreshWorktrees,
          in: resolvedKeybindings
        )
      )
      .disabled(store.state.repositoryRoots.isEmpty && !store.state.isRefreshingWorktrees)
      Button {
        store.send(.selectArchivedWorktrees)
      } label: {
        Image(systemName: store.state.isShowingArchivedWorktrees ? "arrow.uturn.left" : "archivebox")
          .accessibilityLabel(store.state.isShowingArchivedWorktrees ? "Exit Archived Worktrees" : "Archived Worktrees")
      }
      .help(
        AppShortcuts.helpText(
          title: store.state.isShowingArchivedWorktrees ? "Exit Archived Worktrees" : "Archived Worktrees",
          commandID: AppShortcuts.CommandID.archivedWorktrees,
          in: resolvedKeybindings
        ))
      Button {
        openWindow(id: WindowID.settings)
      } label: {
        Image(systemName: "gearshape")
          .accessibilityLabel("Settings")
      }
      .help(
        AppShortcuts.helpText(
          title: "Settings",
          commandID: AppShortcuts.CommandID.openSettings,
          in: resolvedKeybindings
        ))
    }
    .buttonStyle(.plain)
    .interfaceFont(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func activeAgentsPanelIconName(isPanelHidden: Bool) -> String {
    isPanelHidden ? "person.crop.rectangle.stack" : "person.crop.rectangle.stack.fill"
  }
}
