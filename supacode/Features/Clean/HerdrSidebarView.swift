import AppKit
import ComposableArchitecture
import Foundation
import SwiftUI

@MainActor
internal final class HerdrSpacesMenuControl: NSButton {
  internal var menuProvider: @MainActor () -> NSMenu

  internal init(menuProvider: @escaping @MainActor () -> NSMenu) {
    self.menuProvider = menuProvider
    super.init(frame: .zero)
    isBordered = false
    image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Open spaces menu")
    imagePosition = .imageOnly
    contentTintColor = .secondaryLabelColor
    focusRingType = .none
    setButtonType(.momentaryPushIn)
    target = self
    action = #selector(Self.presentMenu(_:))
    toolTip = "Open spaces menu"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc internal func presentMenu(_ sender: Any?) {
    let menu = menuProvider()
    menu.autoenablesItems = false
    menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY), in: self)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    presentMenu(event)
  }
}

private struct HerdrSpacesMenuButton: NSViewRepresentable {
  let menuProvider: @MainActor () -> NSMenu

  @MainActor
  func makeNSView(context: Context) -> HerdrSpacesMenuControl {
    HerdrSpacesMenuControl(menuProvider: menuProvider)
  }

  @MainActor
  func updateNSView(_ nsView: HerdrSpacesMenuControl, context: Context) {
    nsView.menuProvider = menuProvider
  }
}

@MainActor
internal final class HerdrSpacesMenuActionTarget: NSObject {
  internal static let shared = HerdrSpacesMenuActionTarget()
  internal var onNewWorkspace: (() -> Void)?

  @objc internal func newWorkspace(_ sender: Any?) {
    onNewWorkspace?()
  }

  @objc internal func showSettings(_ sender: Any?) {
    SettingsWindowManager.shared.show()
  }

  @objc internal func closeWindow(_ sender: Any?) {
    NSApplication.shared.keyWindow?.performClose(nil)
  }

  @objc internal func quit(_ sender: Any?) {
    NSApplication.shared.terminate(nil)
  }
}

internal enum HerdrSidebarLayout {
  internal static let width: CGFloat = 260
  internal static let smallStatusMarkerSize: CGFloat = 4
  internal static let agentStatusMarkerSize: CGFloat = 9
  internal static let statusMarkerColumnWidth: CGFloat = agentStatusMarkerSize
}

internal enum HerdrChromeTypography {
  internal static let titleFontFamily = "IosevkaTerm Nerd Font"
  internal static let workspaceTitleFontSize: CGFloat = 15
  internal static let agentTitleFontSize: CGFloat = 14.5
  internal static let tabTitleFontSize: CGFloat = 14.5
  internal static let processTitleFontSize: CGFloat = 14.5
  internal static let linkedWorktreeRepoFontSize: CGFloat = 15
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

  internal var markerColor: HerdrAgentStatusColor {
    switch self {
    case .working: return .working
    case .blocked: return .blocked
    case .done: return .unread
    case .idle: return .idle
    case .unknown: return .secondary
    }
  }
}

internal enum HerdrAgentStatusColor: String, Equatable, Sendable {
  case secondary
  case working
  case blocked
  case unread
  case idle
}

internal enum HerdrAgentSortMode: String, Equatable, Sendable {
  case grouped
  case priority

  internal var label: String { rawValue }

  internal mutating func toggle() {
    self = self == .grouped ? .priority : .grouped
  }
}

internal enum HerdrSidebarProjection {
  internal static func agentKind(for agent: HerdrAgent) -> HerdrTabAgentKind {
    HerdrTabAgentKind.resolve(agent)
  }

  internal static func contextLabel(
    for agent: HerdrAgent,
    workspaceLabel: String?,
    tabLabel: String?
  ) -> String {
    var seen = Set<String>()
    return [directoryName(agent), workspaceLabel, tabLabel]
      .compactMap { rawValue in
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, seen.insert(value).inserted else { return nil }
        return value
      }
      .joined(separator: " · ")
  }

  internal static func sortedAgents(
    _ agents: [HerdrAgent],
    mode: HerdrAgentSortMode
  ) -> [HerdrAgent] {
    guard mode == .priority else { return agents }
    return agents.enumerated()
      .sorted { lhs, rhs in
        let lhsRank = attentionRank(lhs.element.agentStatus)
        let rhsRank = attentionRank(rhs.element.agentStatus)
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func attentionRank(_ status: String?) -> Int {
    switch HerdrAgentStatusKind(status) {
    case .blocked: return 4
    case .done: return 3
    case .working: return 2
    case .idle: return 1
    case .unknown: return 0
    }
  }

  private static func directoryName(_ agent: HerdrAgent) -> String? {
    guard let path = agent.foregroundCWD ?? agent.cwd else { return nil }
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else { return nil }
    let name = URL(fileURLWithPath: trimmedPath).lastPathComponent
    return name.isEmpty ? trimmedPath : name
  }
}

private struct HerdrBranchRequest: Sendable {
  let workspaceID: String
  let cwd: String
}

nonisolated private enum HerdrWorkspaceBranchResolver {
  static func resolve(_ requests: [HerdrBranchRequest]) async -> [String: String] {
    await withTaskGroup(of: (String, String?).self, returning: [String: String].self) { group in
      for request in requests {
        group.addTask {
          (request.workspaceID, branch(at: request.cwd))
        }
      }

      var branches: [String: String] = [:]
      for await (workspaceID, branch) in group {
        if let branch, !branch.isEmpty {
          branches[workspaceID] = branch
        }
      }
      return branches
    }
  }

  private static func branch(at cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd, "branch", "--show-current"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

internal struct HerdrSidebarView: View {
  @Bindable internal var store: StoreOf<HerdrTerminalChromeFeature>

  @Environment(\.colorScheme) private var colorScheme
  @State private var agentSortMode: HerdrAgentSortMode = .grouped
  @State private var branchByWorkspaceID: [String: String] = [:]

  internal var body: some View {
    VStack(spacing: 0) {
      spacesSectionHeader
      spacesSection

      Divider()

      agentsSectionHeader
      agentsSection
    }
    .frame(maxHeight: .infinity)
    .overlay(alignment: .trailing) {
      Divider()
    }
    .task(id: branchResolutionKey) {
      let resolvedBranches = await HerdrWorkspaceBranchResolver.resolve(branchRequests)
      guard !Task.isCancelled else { return }
      branchByWorkspaceID = Dictionary(
        uniqueKeysWithValues: store.snapshot.workspaces.compactMap { workspace in
          if let branch = workspace.branch {
            return (workspace.id, branch)
          }
          guard let branch = resolvedBranches[workspace.id] else { return nil }
          return (workspace.id, branch)
        }
      )
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

  private var spacesSectionHeader: some View {
    HStack(spacing: 6) {
      Text("spaces")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      HerdrSpacesMenuButton {
        spacesMenu
      }
      .frame(width: 24, height: 24)
      .foregroundStyle(.secondary)
      .help("Open spaces menu")
      .accessibilityLabel("Open spaces menu")
    }
    .padding(.horizontal, 12)
    .frame(height: 30)
  }

  private var spacesMenu: NSMenu {
    let menu = NSMenu()

    let newWorkspace = NSMenuItem(
      title: "new",
      action: #selector(HerdrSpacesMenuActionTarget.newWorkspace(_:)),
      keyEquivalent: ""
    )
    newWorkspace.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
    newWorkspace.target = HerdrSpacesMenuActionTarget.shared
    newWorkspace.isEnabled = store.pendingMutation == nil
    HerdrSpacesMenuActionTarget.shared.onNewWorkspace = { store.send(.newWorkspaceRequested) }
    menu.addItem(newWorkspace)

    let submenu = NSMenu(title: "menu")
    let menuItem = NSMenuItem(title: "menu", action: nil, keyEquivalent: "")
    menuItem.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Menu")
    menuItem.submenu = submenu
    menu.addItem(menuItem)

    let settings = NSMenuItem(
      title: "settings",
      action: #selector(HerdrSpacesMenuActionTarget.showSettings(_:)),
      keyEquivalent: ""
    )
    settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
    settings.target = HerdrSpacesMenuActionTarget.shared
    submenu.addItem(settings)

    let closeWindow = NSMenuItem(
      title: "close window",
      action: #selector(HerdrSpacesMenuActionTarget.closeWindow(_:)),
      keyEquivalent: ""
    )
    closeWindow.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close window")
    closeWindow.target = HerdrSpacesMenuActionTarget.shared
    submenu.addItem(closeWindow)

    let quit = NSMenuItem(
      title: "quit Prowl",
      action: #selector(HerdrSpacesMenuActionTarget.quit(_:)),
      keyEquivalent: ""
    )
    quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Prowl")
    quit.target = HerdrSpacesMenuActionTarget.shared
    submenu.addItem(quit)

    return menu
  }

  private var agentsSectionHeader: some View {
    HStack(spacing: 6) {
      Text("agents")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Button(agentSortMode.label) {
        agentSortMode.toggle()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.tertiary)
      .help("Toggle agent sorting")
      .accessibilityLabel("Agent sorting: \(agentSortMode.label)")
    }
    .padding(.horizontal, 12)
    .frame(height: 30)
    .accessibilityElement(children: .combine)
  }

  private var sortedAgents: [HerdrAgent] {
    HerdrSidebarProjection.sortedAgents(store.snapshot.agents, mode: agentSortMode)
  }

  private func workspaceRow(_ workspace: HerdrWorkspace) -> some View {
    let selected = store.selectedWorkspaceID == workspace.id
    return Button {
      store.send(.focusWorkspaceTapped(workspace.id))
    } label: {
      HStack(spacing: 8) {
        statusIcon(workspace.agentStatus)
        VStack(alignment: .leading, spacing: 1) {
          Text(workspace.label)
            .font(
              .custom(
                HerdrChromeTypography.titleFontFamily,
                size: HerdrChromeTypography.workspaceTitleFontSize
              )
              .weight(selected ? .semibold : .regular)
            )
            .lineLimit(1)
          if let branch = workspaceBranch(workspace) {
            Text(branch)
              .font(.system(size: 10.5))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
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
    let agentName = agentTitle(agent)
    let context = HerdrSidebarProjection.contextLabel(
      for: agent,
      workspaceLabel: agent.workspaceID.flatMap { workspaceLabel(for: $0) },
      tabLabel: agent.tabID.flatMap { tabLabel(for: $0) }
    )
    let title = context.isEmpty ? agentName : context
    let agentKind = HerdrSidebarProjection.agentKind(for: agent)
    let selected = agent.paneID.map { store.selectedPaneID == $0 } ?? false
    return Button {
      guard let paneID = agent.paneID else { return }
      store.send(.focusPaneTapped(paneID))
    } label: {
      HStack(spacing: 8) {
        statusIcon(agent.agentStatus)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 4) {
            Image(agentKind.iconAssetName)
              .resizable()
              .foregroundStyle(agentKind.accent.color(for: colorScheme))
              .frame(width: 14, height: 14)
              .accessibilityHidden(true)
            Text(title)
              .font(
                .custom(
                  HerdrChromeTypography.titleFontFamily,
                  size: HerdrChromeTypography.agentTitleFontSize,
                )
                .weight(selected ? .semibold : .regular)
              )
              .lineLimit(1)
          }
          if !context.isEmpty {
            Text(agentName)
              .font(.system(size: 10.5))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
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
    let color = markerColor(kind.markerColor)
    if kind.isSmall {
      Circle()
        .fill(color)
        .frame(
          width: HerdrSidebarLayout.smallStatusMarkerSize,
          height: HerdrSidebarLayout.smallStatusMarkerSize
        )
        .frame(
          width: HerdrSidebarLayout.statusMarkerColumnWidth,
          height: HerdrSidebarLayout.agentStatusMarkerSize
        )
        .accessibilityHidden(true)
    } else if kind.isFilled {
      Circle()
        .fill(color)
        .frame(
          width: HerdrSidebarLayout.agentStatusMarkerSize,
          height: HerdrSidebarLayout.agentStatusMarkerSize
        )
        .frame(
          width: HerdrSidebarLayout.statusMarkerColumnWidth,
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
        .frame(
          width: HerdrSidebarLayout.statusMarkerColumnWidth,
          height: HerdrSidebarLayout.agentStatusMarkerSize
        )
        .accessibilityHidden(true)
    }
  }

  private func agentTitle(_ agent: HerdrAgent) -> String {
    [agent.displayAgent, agent.title, agent.name, agent.agent, agent.paneID]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? "agent"
  }

  private func workspaceLabel(for id: String) -> String? {
    store.snapshot.workspaces.first { $0.id == id }?.label
  }

  private func tabLabel(for id: String) -> String? {
    store.snapshot.tabs.first { $0.id == id }?.label
  }

  private var branchRequests: [HerdrBranchRequest] {
    let panesByWorkspaceID = Dictionary(grouping: store.snapshot.panes, by: \.workspaceID)
    var requests: [HerdrBranchRequest] = []
    for workspace in store.snapshot.workspaces {
      guard workspace.branch == nil,
        let panes = panesByWorkspaceID[workspace.id],
        let pane = panes.first(where: \.focused) ?? panes.first,
        let cwd = pane.foregroundCWD ?? pane.cwd
      else { continue }
      requests.append(HerdrBranchRequest(workspaceID: workspace.id, cwd: cwd))
    }
    return requests
  }

  private var branchResolutionKey: String {
    branchRequests.map { "\($0.workspaceID):\($0.cwd)" }.joined(separator: "|")
  }

  private func workspaceBranch(_ workspace: HerdrWorkspace) -> String? {
    workspace.branch ?? branchByWorkspaceID[workspace.id]
  }

  private func statusColor(_ kind: HerdrAgentStatusKind) -> Color {
    markerColor(kind.markerColor)
  }

  private func markerColor(_ color: HerdrAgentStatusColor) -> Color {
    switch color {
    case .blocked: return .red
    case .working: return .yellow
    case .unread: return .teal
    case .idle: return .green
    case .secondary: return .secondary
    }
  }
}
