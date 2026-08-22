import ComposableArchitecture
import SwiftUI

internal enum HerdrSidebarLayout {
  internal static let width: CGFloat = 260
  internal static let minimumWidth: CGFloat = 220
  internal static let maximumWidth: CGFloat = 360
}

internal struct HerdrSidebarView: View {
  @Bindable internal var store: StoreOf<HerdrSidebarFeature>

  internal var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "rectangle.split.3x1")
          .foregroundStyle(.secondary)
        Text("Herdr")
          .font(.headline)
        Spacer(minLength: 0)
        Text("\(store.snapshot.panes.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      Divider()

      if store.snapshot.workspaces.isEmpty {
        ContentUnavailableView("No Herdr panes", systemImage: "rectangle.stack")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(store.snapshot.workspaces) { workspace in
              workspaceSection(workspace)
            }
          }
          .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
      }
    }
    .frame(
      minWidth: HerdrSidebarLayout.minimumWidth,
      maxWidth: HerdrSidebarLayout.maximumWidth,
      maxHeight: .infinity
    )
    .background(.regularMaterial)
    .overlay(alignment: .trailing) {
      Divider()
    }
  }

  @ViewBuilder
  private func workspaceSection(_ workspace: HerdrWorkspace) -> some View {
    rowButton(
      title: workspace.label,
      subtitle: workspaceSubtitle(workspace),
      systemImage: "square.stack.3d.up",
      isSelected: store.selectedWorkspaceID == workspace.id,
      isPending: isPending(.workspace(workspace.id)),
      help: "Focus workspace \(workspace.label)"
    ) {
      store.send(.focusWorkspaceTapped(workspace.id))
    }

    ForEach(tabs(in: workspace)) { tab in
      VStack(alignment: .leading, spacing: 2) {
        rowButton(
          title: tab.label,
          subtitle: tabSubtitle(tab),
          systemImage: "rectangle.split.2x1",
          isSelected: store.selectedTabID == tab.id,
          isPending: isPending(.tab(tab.id)),
          indentation: 16,
          help: "Focus tab \(tab.label)"
        ) {
          store.send(.focusTabTapped(tab.id))
        }

        ForEach(panes(in: tab)) { pane in
          rowButton(
            title: paneTitle(pane),
            subtitle: paneSubtitle(pane),
            systemImage: pane.isAgent ? "sparkles.rectangle.stack" : "terminal",
            isSelected: store.selectedPaneID == pane.id,
            isPending: isPending(.pane(pane.id)),
            indentation: 32,
            help: "Focus pane \(paneTitle(pane))"
          ) {
            store.send(.focusPaneTapped(pane.id))
          }
        }
      }
    }
  }

  private func tabs(in workspace: HerdrWorkspace) -> [HerdrTab] {
    store.snapshot.tabs.filter { $0.workspaceID == workspace.id }
  }

  private func panes(in tab: HerdrTab) -> [HerdrPane] {
    store.snapshot.panes.filter { $0.tabID == tab.id }
  }

  private func workspaceSubtitle(_ workspace: HerdrWorkspace) -> String? {
    let counts = [
      workspace.tabCount.map { "\($0) \($0 == 1 ? "tab" : "tabs")" },
      workspace.paneCount.map { "\($0) \($0 == 1 ? "pane" : "panes")" },
    ].compactMap { $0 }
    return counts.isEmpty ? nil : counts.joined(separator: " · ")
  }

  private func tabSubtitle(_ tab: HerdrTab) -> String? {
    guard let paneCount = tab.paneCount else { return nil }
    return "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
  }

  private func paneTitle(_ pane: HerdrPane) -> String {
    [pane.label, pane.displayAgent, pane.title, pane.terminalTitleStripped, pane.foregroundCWD, pane.paneID]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? pane.paneID
  }

  private func paneSubtitle(_ pane: HerdrPane) -> String? {
    guard pane.isAgent else {
      return pane.foregroundCWD ?? pane.cwd
    }
    let agentName = pane.displayAgent ?? pane.agent
    switch (agentName, pane.agentStatus) {
    case let (agent?, status?):
      return "\(agent) · \(status)"
    case let (agent?, nil):
      return agent
    case let (nil, status?):
      return status
    case (nil, nil):
      return nil
    }
  }

  private func isPending(_ target: HerdrSidebarFeature.FocusTarget) -> Bool {
    store.pendingFocus == target
  }

  private func rowButton(
    title: String,
    subtitle: String?,
    systemImage: String,
    isSelected: Bool,
    isPending: Bool,
    indentation: CGFloat = 0,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .frame(width: 16)
          .foregroundStyle(isSelected ? .primary : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .lineLimit(1)
          if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        if isPending {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.vertical, 5)
      .padding(.leading, 8 + indentation)
      .padding(.trailing, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 5)
          .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(title)
  }
}
