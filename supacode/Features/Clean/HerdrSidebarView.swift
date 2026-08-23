import ComposableArchitecture
import SwiftUI

internal enum HerdrSidebarLayout {
  internal static let width: CGFloat = 260
  internal static let smallStatusMarkerSize: CGFloat = 4
  internal static let agentStatusMarkerSize: CGFloat = 11
}

internal enum HerdrAgentStatusKind: String, Equatable, Sendable {
  case unknown
  case working
  case blocked
  case done
  case idle

  internal init(_ status: String?) {
    switch status {
    case "working": self = .working
    case "blocked": self = .blocked
    case "done": self = .done
    case "idle": self = .idle
    default: self = .unknown
    }
  }

  internal var isSmall: Bool {
    self == .unknown
  }

  internal var isFilled: Bool {
    self != .idle
  }
}

internal struct HerdrSidebarView: View {
  @Bindable internal var store: StoreOf<HerdrTerminalChromeFeature>

  internal var body: some View {
    VStack(spacing: 0) {
      sidebarSectionHeader(title: "spaces", detail: "\(store.snapshot.workspaces.count)")
      spacesSection

      Divider()

      sidebarSectionHeader(title: "agents", detail: "grouped")
      agentsSection

      footer
    }
    .frame(maxHeight: .infinity)
    .glassEffect(.regular, in: Rectangle())
    .overlay(alignment: .trailing) {
      Divider()
    }
  }

  private var spacesSection: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(store.snapshot.workspaces) { workspace in
          workspaceRow(workspace)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .scrollIndicators(.never)
    .frame(maxHeight: .infinity)
  }

  private var agentsSection: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(sortedAgents) { agent in
          agentRow(agent)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .scrollIndicators(.never)
    .frame(maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Text("new")
      Spacer()
      Text("menu")
    }
    .font(.caption)
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 12)
    .frame(height: 30)
  }

  private var sortedAgents: [HerdrAgent] {
    store.snapshot.agents.sorted { lhs, rhs in
      let lhsRank = statusRank(lhs.agentStatus)
      let rhsRank = statusRank(rhs.agentStatus)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      return agentTitle(lhs).localizedStandardCompare(agentTitle(rhs)) == .orderedAscending
    }
  }

  @ViewBuilder
  private func sidebarSectionHeader(title: String, detail: String) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Text(detail)
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .frame(height: 30)
    .accessibilityElement(children: .combine)
  }

  private func workspaceRow(_ workspace: HerdrWorkspace) -> some View {
    let selected = store.selectedWorkspaceID == workspace.id
    return Button {
      store.send(.focusWorkspaceTapped(workspace.id))
    } label: {
      HStack(spacing: 8) {
        Circle()
          .fill(selected ? Color.accentColor : Color.secondary.opacity(0.65))
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(workspace.label)
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .lineLimit(1)
          Text(workspaceSubtitle(workspace))
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if workspace.focused {
          Image(systemName: "circle.fill")
            .font(.system(size: 5))
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 38)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(selected ? Color.accentColor.opacity(0.14) : .clear)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Focus workspace \(workspace.label)")
    .accessibilityLabel("Focus workspace \(workspace.label)")
  }

  private func agentRow(_ agent: HerdrAgent) -> some View {
    let title = agentTitle(agent)
    let selected = agent.paneID.map { store.selectedPaneID == $0 } ?? false
    return Button {
      guard let paneID = agent.paneID else { return }
      store.send(.focusPaneTapped(paneID))
    } label: {
      HStack(spacing: 8) {
        statusIcon(agent.agentStatus)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .lineLimit(1)
          Text(agentSubtitle(agent))
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if let status = agent.agentStatus, status != "idle" {
          Text(status)
            .font(.system(size: 10))
            .foregroundStyle(statusColor(HerdrAgentStatusKind(status)))
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 42)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(selected ? Color.accentColor.opacity(0.14) : .clear)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Focus pane \(title)")
    .accessibilityLabel("Focus agent \(title)")
    .disabled(agent.paneID == nil)
  }

  @ViewBuilder
  private func statusIcon(_ status: String?) -> some View {
    let kind = HerdrAgentStatusKind(status)
    let color = statusColor(kind)
    if kind.isSmall {
      Circle()
        .fill(color)
        .frame(
          width: HerdrSidebarLayout.smallStatusMarkerSize,
          height: HerdrSidebarLayout.smallStatusMarkerSize
        )
        .accessibilityHidden(true)
    } else if kind.isFilled {
      Circle()
        .fill(color)
        .frame(
          width: HerdrSidebarLayout.agentStatusMarkerSize,
          height: HerdrSidebarLayout.agentStatusMarkerSize
        )
        .accessibilityHidden(true)
    } else {
      Circle()
        .strokeBorder(color, lineWidth: 1.5)
        .frame(
          width: HerdrSidebarLayout.agentStatusMarkerSize,
          height: HerdrSidebarLayout.agentStatusMarkerSize
        )
        .accessibilityHidden(true)
    }
  }

  private func workspaceSubtitle(_ workspace: HerdrWorkspace) -> String {
    let tabCount = workspace.tabCount.map { "\($0) \($0 == 1 ? "tab" : "tabs")" }
    let paneCount = workspace.paneCount.map { "\($0) \($0 == 1 ? "pane" : "panes")" }
    return [tabCount, paneCount].compactMap { $0 }.joined(separator: " · ")
  }

  private func agentTitle(_ agent: HerdrAgent) -> String {
    [agent.displayAgent, agent.title, agent.name, agent.agent, agent.paneID]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? "agent"
  }

  private func agentSubtitle(_ agent: HerdrAgent) -> String {
    let workspace = agent.workspaceID.flatMap { workspaceLabel(for: $0) }
    let tab = agent.tabID.flatMap { tabLabel(for: $0) }
    return [agent.agent, workspace, tab].compactMap { $0 }.joined(separator: " · ")
  }

  private func workspaceLabel(for id: String) -> String? {
    store.snapshot.workspaces.first { $0.id == id }?.label
  }

  private func tabLabel(for id: String) -> String? {
    store.snapshot.tabs.first { $0.id == id }?.label
  }

  private func statusRank(_ status: String?) -> Int {
    switch status {
    case "blocked": return 0
    case "done": return 1
    case "working": return 2
    case "idle": return 3
    default: return 4
    }
  }

  private func statusColor(_ kind: HerdrAgentStatusKind) -> Color {
    switch kind {
    case .blocked: return .orange
    case .done: return .green
    case .working: return .blue
    default: return .secondary
    }
  }
}
