import AppKit
import ComposableArchitecture
import SwiftUI

internal enum HerdrTabBarLayout {
  internal static let height: CGFloat = 34
  internal static let minimumTabWidth: CGFloat = 46
  internal static let barLeadingPadding: CGFloat = 0
  internal static let tabTextLeadingPadding: CGFloat = 18
  internal static let tabTrailingPadding: CGFloat = 6
  internal static let tabSpacing: CGFloat = 3
  internal static let closeButtonSize: CGFloat = 18
  internal static let visibilityThreshold = 0.5
}

internal struct HerdrLinkedWorktreeTitle: Equatable, Sendable {
  internal let repoName: String
  internal let checkoutName: String

  internal var displayLabel: String {
    "\(repoName) ↳ \(checkoutName)"
  }
}

internal struct HerdrProcessTitle: Equatable, Sendable {
  internal let processName: String
  internal let directoryName: String
  internal let linkedWorktree: HerdrLinkedWorktreeTitle?

  internal init(
    processName: String,
    directoryName: String,
    linkedWorktree: HerdrLinkedWorktreeTitle? = nil
  ) {
    self.processName = processName
    self.directoryName = directoryName
    self.linkedWorktree = linkedWorktree
  }

  internal var displayLabel: String {
    "\(processName) ・ \(directoryName)"
  }

  internal var accent: HerdrProcessAccent {
    switch processName {
    case "lazygit", "gitui": return .versionControl
    case "codex", "omp", "pi", "claude", "claude-code", "opencode": return .agent
    case "vim", "nvim", "vi": return .editor
    default: return .neutral
    }
  }

  internal var icon: HerdrProcessIcon? {
    HerdrProcessIcon(processName: processName)
  }

  /// Badge-carrying processes replace the process-name text with their
  /// leading icon; the badge alone identifies what is running.
  internal var rendersIconOnly: Bool {
    icon != nil
  }
}

internal enum HerdrProcessAccent: Equatable, Sendable {
  case versionControl
  case agent
  case editor
  case neutral

  internal func color(for colorScheme: ColorScheme) -> Color {
    switch self {
    case .versionControl: return .orange
    case .agent: return .cyan
    case .editor: return .green
    case .neutral: return colorScheme == .dark ? .primary : .secondary
    }
  }
}

internal enum HerdrProcessIcon: String, Equatable, Sendable {
  /// Leading tab icon for remote-shell foreground processes. Driven by the
  /// daemon-reported foreground process, so the badge tracks the live session:
  /// it appears while `ssh`/`mosh-client` owns the pane and drops off when the
  /// shell regains the foreground. Extend the switch as more remote transports
  /// earn distinct artwork.
  case ssh = "HerdrProcessSshIcon"

  internal init?(processName: String) {
    switch processName.lowercased() {
    case "ssh", "mosh-client": self = .ssh
    default: return nil
    }
  }
}

internal enum HerdrTabTitleTone: Equatable, Sendable {
  case primary
  case secondary
  case tertiary
}

internal enum HerdrTabAgentAccent: Equatable, Sendable {
  case systemPrimary
  case systemSecondary
  case claude
  case pi
  case cursor
  case opencode
  case omp

  internal func color(for colorScheme: ColorScheme) -> Color {
    switch self {
    case .systemPrimary: return .primary
    case .systemSecondary: return .secondary
    case .claude: return Self.rgb(red: 217, green: 119, blue: 87)
    case .pi: return Self.rgb(red: 109, green: 93, blue: 251)
    case .cursor:
      return colorScheme == .dark
        ? Self.rgb(red: 245, green: 245, blue: 245)
        : Self.rgb(red: 17, green: 24, blue: 39)
    case .opencode: return Self.rgb(red: 37, green: 99, blue: 235)
    case .omp: return Self.rgb(red: 147, green: 51, blue: 234)
    }
  }

  private static func rgb(red: Double, green: Double, blue: Double) -> Color {
    Color(red: red / 255, green: green / 255, blue: blue / 255)
  }
}

internal enum HerdrTabAgentIcon: String, Equatable, Sendable {
  case generic = "HerdrAgentIcon"
  case codex = "HerdrAgentCodexIcon"
  case claude = "HerdrAgentClaudeIcon"
  case pi = "HerdrAgentPiIcon"
  case cursor = "HerdrAgentCursorIcon"
  case opencode = "HerdrAgentOpencodeIcon"
  case omp = "HerdrAgentOmpIcon"
  case grok = "HerdrAgentGrokIcon"

  internal var accent: HerdrTabAgentAccent {
    switch self {
    case .generic: return .systemSecondary
    case .codex, .grok: return .systemPrimary
    case .claude: return .claude
    case .pi: return .pi
    case .cursor: return .cursor
    case .opencode: return .opencode
    case .omp: return .omp
    }
  }

  internal static func resolve(_ agent: HerdrAgent) -> Self {
    for rawIdentifier in [agent.agent, agent.displayAgent, agent.name].compactMap({ $0 }) {
      let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      switch identifier {
      case "codex", "openai": return .codex
      case "claude", "claude-code", "claude_code", "claude code", "anthropic": return .claude
      case "pi": return .pi
      case "cursor", "acp-cursor": return .cursor
      case "opencode", "open-code", "acp-opencode": return .opencode
      case "omp", "acp-omp", "oh-my-pi": return .omp
      case "grok", "grok-build", "acp-grok": return .grok
      default: continue
      }
    }
    return .generic
  }
}

internal struct HerdrTabBarItem: Equatable, Identifiable, Sendable {
  internal let id: String
  internal let workspaceID: String
  internal let label: String
  internal let customName: String?
  internal let isZoomed: Bool
  internal let isFocused: Bool
  internal let agentIcon: HerdrTabAgentIcon?
  internal let processTitle: HerdrProcessTitle?
  internal let linkedWorktree: HerdrLinkedWorktreeTitle?

  internal var isAgent: Bool {
    agentIcon != nil
  }

  internal var processIcon: HerdrProcessIcon? {
    processTitle?.icon
  }

  internal init(
    id: String,
    workspaceID: String,
    label: String,
    isZoomed: Bool,
    isFocused: Bool,
    customName: String? = nil,
    isAgent: Bool = false,
    agentIcon: HerdrTabAgentIcon? = nil,
    processTitle: HerdrProcessTitle? = nil,
    linkedWorktree: HerdrLinkedWorktreeTitle? = nil
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.label = label
    self.customName = customName
    self.isZoomed = isZoomed
    self.isFocused = isFocused
    self.agentIcon = agentIcon ?? (isAgent ? .generic : nil)
    self.processTitle = processTitle
    self.linkedWorktree = linkedWorktree
  }

  internal var displayLabel: String {
    if let processTitle {
      return "\(processTitle.processName) ・ \(directoryLabel)"
    }
    return isZoomed ? "\(directoryLabel) Z" : directoryLabel
  }

  internal var directoryLabel: String {
    customName == nil ? linkedWorktree?.displayLabel ?? label : label
  }
}

internal enum HerdrTabBarProjection {
  internal static func contextTone(isActive: Bool) -> HerdrTabTitleTone {
    isActive ? .primary : .secondary
  }

  internal static func linkedRepoTone(isActive: Bool) -> HerdrTabTitleTone {
    isActive ? .primary : .secondary
  }

  internal static func linkedCheckoutTone(isActive: Bool) -> HerdrTabTitleTone {
    isActive ? .secondary : .tertiary
  }

  internal static func processTitle(
    in processInfo: HerdrPaneProcessInfo,
    fallbackDirectory: String?,
    linkedWorktree: HerdrLinkedWorktreeTitle? = nil
  ) -> HerdrProcessTitle? {
    let candidates = processInfo.foregroundProcesses.filter { process in
      guard process.pid != processInfo.shellPID else { return false }
      guard let name = processName(for: process) else { return false }
      return !ignoredProcessNames.contains(name)
    }
    guard
      let process = candidates.first(where: {
        $0.pid == processInfo.foregroundProcessGroupID
      }) ?? candidates.min(by: { $0.pid < $1.pid }),
      let processName = processName(for: process),
      let directoryName = directoryName(for: process.cwd ?? fallbackDirectory)
    else { return nil }
    guard !knownAgentProcessNames.contains(processName) else { return nil }
    if let linkedWorktree {
      return HerdrProcessTitle(
        processName: processName,
        directoryName: linkedWorktree.displayLabel,
        linkedWorktree: linkedWorktree
      )
    }
    return HerdrProcessTitle(processName: processName, directoryName: directoryName)
  }

  internal static func items(
    in snapshot: HerdrSessionSnapshot,
    workspaceID: String?,
    processInfoByPaneID: [String: HerdrPaneProcessInfo] = [:],
    focusedPaneID: String? = nil
  ) -> [HerdrTabBarItem] {
    guard let workspaceID else { return [] }
    let zoomedTabIDs = Set(
      snapshot.layouts
        .filter { $0.workspaceID == workspaceID && $0.zoomed }
        .map(\.tabID)
    )
    let agentIconsByTabID = snapshot.agents.reduce(into: [String: HerdrTabAgentIcon]()) {
      icons, agent in
      guard let tabID = agent.tabID else { return }
      let icon = HerdrTabAgentIcon.resolve(agent)
      guard let existingIcon = icons[tabID] else {
        icons[tabID] = icon
        return
      }
      if icon != .generic, existingIcon == .generic || agent.focused {
        icons[tabID] = icon
      }
    }
    let panesByTabID = Dictionary(grouping: snapshot.panes, by: \.tabID)
    let worktreesByWorkspaceID = snapshot.workspaces.reduce(
      into: [String: HerdrWorkspaceWorktree]()
    ) {
      worktrees, workspace in
      if let worktree = workspace.worktree {
        worktrees[workspace.id] = worktree
      }
    }
    let linkedWorktreesByWorkspaceID = worktreesByWorkspaceID.reduce(
      into: [String: HerdrLinkedWorktreeTitle]()
    ) {
      result, entry in
      if let title = linkedWorktreeTitle(for: entry.value) {
        result[entry.key] = title
      }
    }
    var processTitlesByTabID: [String: HerdrProcessTitle] = [:]
    for (tabID, panes) in panesByTabID {
      let orderedPanes = panes.sorted {
        if $0.id == focusedPaneID { return true }
        if $1.id == focusedPaneID { return false }
        return $0.focused && !$1.focused
      }
      guard let representativePane = orderedPanes.first else { continue }
      let linkedWorktree = linkedWorktreesByWorkspaceID[representativePane.workspaceID]
      let processTitle =
        orderedPanes
        .compactMap { pane -> HerdrProcessTitle? in
          guard let processInfo = processInfoByPaneID[pane.id] else { return nil }
          return Self.processTitle(
            in: processInfo,
            fallbackDirectory: pane.foregroundCWD ?? pane.cwd,
            linkedWorktree: linkedWorktree
          )
        }
        .first
      if let processTitle {
        processTitlesByTabID[tabID] = processTitle
      }
    }
    return snapshot.tabs.compactMap { tab in
      guard tab.workspaceID == workspaceID else { return nil }
      return HerdrTabBarItem(
        id: tab.id,
        workspaceID: tab.workspaceID,
        label: tab.label,
        isZoomed: zoomedTabIDs.contains(tab.id),
        isFocused: tab.id == snapshot.focusedTabID || tab.focused,
        customName: tab.customName,
        agentIcon: agentIconsByTabID[tab.id],
        processTitle: processTitlesByTabID[tab.id],
        linkedWorktree: linkedWorktreesByWorkspaceID[tab.workspaceID]
      )
    }
  }

  private static let ignoredProcessNames: Set<String> = [
    "ash", "bash", "command", "dash", "env", "fish", "git", "ksh", "login", "nu",
    "pwsh", "sh", "sleep", "starship", "sudo", "tcsh", "zsh",
  ]
  private static let knownAgentProcessNames: Set<String> = [
    "amp", "claude", "claude-code", "codex", "copilot", "cursor", "gemini", "kimi", "omp",
    "opencode", "pi",
  ]

  private static func processName(for process: HerdrPaneProcess) -> String? {
    ProcessDetection.basename(process.argv0 ?? process.name)?.lowercased()
  }

  private static func directoryName(for path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalizedPath.isEmpty else { return "/" }
    return URL(fileURLWithPath: "/\(normalizedPath)").lastPathComponent
  }

  private static func linkedWorktreeTitle(
    for worktree: HerdrWorkspaceWorktree?
  ) -> HerdrLinkedWorktreeTitle? {
    guard
      let worktree,
      worktree.isLinkedWorktree,
      !worktree.repoName.isEmpty,
      let checkoutName = directoryName(for: worktree.checkoutPath),
      !checkoutName.isEmpty
    else { return nil }
    return HerdrLinkedWorktreeTitle(repoName: worktree.repoName, checkoutName: checkoutName)
  }

  internal static func insertIndex(
    sourceID: String,
    targetID: String,
    items: [HerdrTabBarItem]
  ) -> Int? {
    guard sourceID != targetID,
      let targetIndex = items.firstIndex(where: { $0.id == targetID })
    else { return nil }
    return targetIndex
  }

  internal static func cycleTarget(
    selectedID: String?,
    direction: Int,
    items: [HerdrTabBarItem]
  ) -> String? {
    guard !items.isEmpty else { return nil }
    let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
    let nextIndex = (currentIndex + direction + items.count) % items.count
    return items[nextIndex].id
  }

  internal static func shouldShowActiveTreatment(
    itemID: String,
    selectedID: String?
  ) -> Bool {
    itemID == selectedID
  }

  internal static func shouldScrollToSelected(
    selectedID: String?,
    visibleIDs: Set<String>
  ) -> Bool {
    guard let selectedID else { return false }
    return !visibleIDs.contains(selectedID)
  }
}

internal struct HerdrTabBarView: View {
  @Bindable internal var store: StoreOf<HerdrTerminalChromeFeature>
  internal var processInfoByPaneID: [String: HerdrPaneProcessInfo] = [:]

  @Environment(\.colorScheme) private var colorScheme
  @State private var editor: Editor?
  @State private var hoveredTabID: String?
  @State private var visibleTabIDs: Set<String> = []

  private enum Editor: Identifiable {
    case new(workspaceID: String, sourceTabID: String?)
    case rename(tabID: String, label: String, canReset: Bool)

    internal var id: String {
      switch self {
      case .new(let workspaceID, let sourceTabID):
        return "new-\(workspaceID)-\(sourceTabID ?? "current")"
      case .rename(let tabID, _, _): return "rename-\(tabID)"
      }
    }
  }

  internal var body: some View {
    let items = tabItems
    let selectedID = store.selectedTabID ?? items.first(where: { $0.isFocused })?.id
    HStack(spacing: 6) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: HerdrTabBarLayout.tabSpacing) {
            ForEach(items) { item in
              tabButton(item, selectedID: selectedID, items: items)
                .id(item.id)
                .onScrollVisibilityChange(threshold: HerdrTabBarLayout.visibilityThreshold) {
                  isVisible in
                  if isVisible {
                    visibleTabIDs.insert(item.id)
                  } else {
                    visibleTabIDs.remove(item.id)
                  }
                }
            }
          }
          .padding(.leading, HerdrTabBarLayout.barLeadingPadding)
          .padding(.trailing, 4)
        }
        .scrollIndicators(.never)
        .onAppear {
          scrollToSelected(proxy, selectedID: store.selectedTabID)
        }
        .onChange(of: store.selectedTabID) { _, selectedID in
          scrollToSelected(proxy, selectedID: selectedID)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Button {
        guard let workspaceID else { return }
        store.send(.newTabRequested(workspaceID: workspaceID, label: nil, sourceTabID: nil))
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .contentShape(.rect)
      .help("New tab")
      .accessibilityLabel("New tab")
      .disabled(workspaceID == nil || store.pendingMutation != nil)
    }
    .padding(.leading, HerdrTabBarLayout.barLeadingPadding)
    .padding(.trailing, 8)
    .frame(height: HerdrTabBarLayout.height)
    .background {
      HerdrTabBarScrollInterceptor { delta in
        let direction = delta > 0 ? -1 : 1
        guard
          let targetID = HerdrTabBarProjection.cycleTarget(
            selectedID: store.selectedTabID,
            direction: direction,
            items: items
          )
        else { return }
        store.send(.focusTabTapped(targetID))
      }
    }
    .sheet(item: $editor) { editor in
      editorView(editor)
    }
    .alert(
      "Close workspace?",
      isPresented: closeConfirmationBinding
    ) {
      Button("Close", role: .destructive) {
        store.send(.closeConfirmationConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.closeConfirmationCancelled)
      }
    } message: {
      Text("Closing the last tab will close its Herdr workspace.")
    }
    .alert(
      "Herdr tab action failed",
      isPresented: mutationErrorBinding
    ) {
      Button("OK", role: .cancel) {
        store.send(.mutationErrorDismissed)
      }
    } message: {
      Text(mutationErrorMessage)
    }
  }

  private var workspaceID: String? {
    store.selectedWorkspaceID ?? store.snapshot.focusedWorkspaceID
  }

  private var tabItems: [HerdrTabBarItem] {
    HerdrTabBarProjection.items(
      in: store.snapshot,
      workspaceID: workspaceID,
      processInfoByPaneID: processInfoByPaneID,
      focusedPaneID: store.selectedPaneID ?? store.snapshot.focusedPaneID
    )
  }

  private func scrollToSelected(_ proxy: ScrollViewProxy, selectedID: String?) {
    guard
      HerdrTabBarProjection.shouldScrollToSelected(
        selectedID: selectedID,
        visibleIDs: visibleTabIDs
      ),
      let selectedID
    else { return }
    proxy.scrollTo(selectedID, anchor: .center)
  }

  private func tabButton(
    _ item: HerdrTabBarItem,
    selectedID: String?,
    items: [HerdrTabBarItem]
  ) -> some View {
    let isActive = HerdrTabBarProjection.shouldShowActiveTreatment(
      itemID: item.id,
      selectedID: selectedID
    )
    let isHovered = hoveredTabID == item.id
    return ZStack(alignment: .trailing) {
      Button {
        store.send(.focusTabTapped(item.id))
      } label: {
        HStack(spacing: 3) {
          if let agentIcon = item.agentIcon {
            Image(agentIcon.rawValue)
              .resizable()
              .foregroundStyle(agentIcon.accent.color(for: colorScheme))
              .frame(width: 14, height: 14)
              .accessibilityHidden(true)
          } else if let processIcon = item.processIcon {
            Image(processIcon.rawValue)
              .resizable()
              .foregroundStyle(.green)
              .frame(width: 14, height: 14)
              .accessibilityHidden(true)
          }
          tabTitleLabel(item, isActive: isActive)
          Color.clear
            .frame(width: HerdrTabBarLayout.closeButtonSize)
        }
        .padding(.leading, HerdrTabBarLayout.tabTextLeadingPadding)
        .padding(.trailing, HerdrTabBarLayout.tabTrailingPadding)
        .frame(minHeight: 26)
        .background {
          Rectangle()
            .fill(
              isActive
                ? Color.accentColor.opacity(0.2) : isHovered ? Color.primary.opacity(0.07) : .clear)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      if isHovered {
        Button {
          store.send(
            .closeTabRequested(tabID: item.id, workspaceID: item.workspaceID)
          )
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .frame(
              width: HerdrTabBarLayout.closeButtonSize, height: HerdrTabBarLayout.closeButtonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .padding(.trailing, HerdrTabBarLayout.tabTrailingPadding)
        .help("Close tab")
        .accessibilityLabel("Close tab \(item.displayLabel)")
        .disabled(store.pendingMutation != nil)
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(isActive ? .primary : .secondary)
    .onHover { hoveredTabID = $0 ? item.id : nil }
    .help("Open tab \(item.displayLabel)")
    .accessibilityLabel(item.displayLabel)
    .contextMenu {
      Button("New tab") {
        editor = .new(workspaceID: item.workspaceID, sourceTabID: item.id)
      }
      Button("Rename Directory Name…") {
        editor = .rename(
          tabID: item.id,
          label: item.label,
          canReset: item.customName != nil
        )
      }
      if item.customName != nil {
        Button("Use Automatic Directory Name") {
          store.send(.resetTabNameRequested(item.id))
        }
        .disabled(store.pendingMutation != nil)
      }
      Divider()
      Button("Close", role: .destructive) {
        store.send(.closeTabRequested(tabID: item.id, workspaceID: item.workspaceID))
      }
      .disabled(store.pendingMutation != nil)
    }
    .draggable(item.id)
    .dropDestination(for: String.self) { sourceIDs, _ in
      guard let sourceID = sourceIDs.first,
        let insertIndex = HerdrTabBarProjection.insertIndex(
          sourceID: sourceID,
          targetID: item.id,
          items: items
        )
      else { return false }
      store.send(.moveTabRequested(tabID: sourceID, insertIndex: insertIndex))
      return true
    }
  }

  @ViewBuilder
  private func tabTitleLabel(_ item: HerdrTabBarItem, isActive: Bool) -> some View {
    if let processTitle = item.processTitle, !processTitle.rendersIconOnly {
      HStack(spacing: 3) {
        Text(processTitle.processName)
          .font(
            .custom(
              HerdrChromeTypography.titleFontFamily,
              size: HerdrChromeTypography.processTitleFontSize
            )
            .weight(isActive ? .semibold : .medium)
          )
          .foregroundStyle(processTitle.accent.color(for: colorScheme))
        Text("・")
          .font(.system(size: 8))
          .foregroundStyle(.secondary)
          .offset(y: -0.5)
        directorySegmentLabel(item, isActive: isActive)
      }
      .lineLimit(1)
      .truncationMode(.middle)
      .frame(minWidth: HerdrTabBarLayout.minimumTabWidth, alignment: .leading)
    } else {
      directorySegmentLabel(item, isActive: isActive)
        .frame(minWidth: HerdrTabBarLayout.minimumTabWidth, alignment: .leading)
    }
  }

  @ViewBuilder
  private func directorySegmentLabel(_ item: HerdrTabBarItem, isActive: Bool) -> some View {
    if item.customName == nil, let linkedWorktree = item.linkedWorktree {
      linkedWorktreeTitleLabel(linkedWorktree, isActive: isActive)
    } else {
      Text(item.directoryLabel)
        .font(
          .custom(
            HerdrChromeTypography.titleFontFamily,
            size: HerdrChromeTypography.tabTitleFontSize
          )
          .weight(isActive ? .semibold : .medium)
        )
        .foregroundStyle(titleColor(HerdrTabBarProjection.contextTone(isActive: isActive)))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private func linkedWorktreeTitleLabel(
    _ linkedWorktree: HerdrLinkedWorktreeTitle,
    isActive: Bool
  ) -> some View {
    HStack(spacing: 3) {
      Text(linkedWorktree.repoName)
        .font(
          .custom(
            HerdrChromeTypography.titleFontFamily,
            size: HerdrChromeTypography.linkedWorktreeRepoFontSize
          )
          .weight(isActive ? .semibold : .medium)
        )
        .foregroundStyle(titleColor(HerdrTabBarProjection.linkedRepoTone(isActive: isActive)))
      Text("↳")
        .font(
          .custom(
            HerdrChromeTypography.titleFontFamily,
            size: HerdrChromeTypography.processTitleFontSize
          )
          .weight(isActive ? .semibold : .medium)
        )
        .foregroundStyle(
          titleColor(HerdrTabBarProjection.linkedCheckoutTone(isActive: isActive)))
      Text(linkedWorktree.checkoutName)
        .font(
          .custom(
            HerdrChromeTypography.titleFontFamily,
            size: HerdrChromeTypography.processTitleFontSize
          )
          .weight(isActive ? .semibold : .medium)
        )
        .foregroundStyle(
          titleColor(HerdrTabBarProjection.linkedCheckoutTone(isActive: isActive)))
    }
    .lineLimit(1)
    .truncationMode(.middle)
  }

  private func titleColor(_ tone: HerdrTabTitleTone) -> AnyShapeStyle {
    switch tone {
    case .primary: return AnyShapeStyle(.primary)
    case .secondary: return AnyShapeStyle(.secondary)
    case .tertiary: return AnyShapeStyle(.tertiary)
    }
  }

  @ViewBuilder
  private func editorView(_ editor: Editor) -> some View {
    switch editor {
    case .new(let workspaceID, let sourceTabID):
      HerdrTabEditorView(title: "New tab", label: "", isOptional: true) { label in
        store.send(
          .newTabRequested(
            workspaceID: workspaceID,
            label: label,
            sourceTabID: sourceTabID
          )
        )
      }
    case .rename(let tabID, let label, let canReset):
      HerdrTabEditorView(
        title: "Rename Directory Name",
        label: label,
        isOptional: false,
        canReset: canReset,
        onReset: {
          store.send(.resetTabNameRequested(tabID))
        },
        onSubmit: { label in
          guard let label else { return }
          store.send(.renameTabRequested(tabID: tabID, label: label))
        }
      )
    }
  }

  private var closeConfirmationBinding: Binding<Bool> {
    Binding(
      get: { store.closeConfirmation != nil },
      set: { isPresented in
        if !isPresented {
          store.send(.closeConfirmationCancelled)
        }
      }
    )
  }

  private var mutationErrorBinding: Binding<Bool> {
    Binding(
      get: { store.mutationError != nil },
      set: { isPresented in
        if !isPresented {
          store.send(.mutationErrorDismissed)
        }
      }
    )
  }

  private var mutationErrorMessage: String {
    guard let error = store.mutationError else { return "Unknown Herdr error." }
    return String(describing: error)
  }
}

private struct HerdrTabBarScrollInterceptor: NSViewRepresentable {
  let onScroll: @MainActor (CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScroll: onScroll)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.start(for: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    private let onScroll: @MainActor (CGFloat) -> Void
    private var monitor: Any?
    private weak var view: NSView?

    init(onScroll: @escaping @MainActor (CGFloat) -> Void) {
      self.onScroll = onScroll
    }

    func start(for view: NSView) {
      guard monitor == nil else { return }
      self.view = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, let view = self.view, view.window != nil else { return event }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point) else { return event }
        onScroll(event.scrollingDeltaY)
        return nil
      }
    }

    func stop() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      view = nil
    }
  }
}

private struct HerdrTabEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFocused: Bool
  @State private var label: String

  let title: String
  let isOptional: Bool
  let canReset: Bool
  let onReset: (() -> Void)?
  let onSubmit: (String?) -> Void

  init(
    title: String,
    label: String,
    isOptional: Bool,
    canReset: Bool = false,
    onReset: (() -> Void)? = nil,
    onSubmit: @escaping (String?) -> Void
  ) {
    self.title = title
    self.isOptional = isOptional
    self.canReset = canReset
    self.onReset = onReset
    self.onSubmit = onSubmit
    _label = State(initialValue: label)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.headline)
      TextField(isOptional ? "Tab name (optional)" : "Tab name", text: $label)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit(submit)
      HStack {
        if canReset, let onReset {
          Button("Use Automatic Name") {
            onReset()
            dismiss()
          }
          .help("Remove the custom name and follow the active directory.")
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(!isOptional && trimmedLabel.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 340)
    .onAppear { isFocused = true }
  }

  private var trimmedLabel: String {
    label.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submit() {
    let value = trimmedLabel
    guard isOptional || !value.isEmpty else { return }
    onSubmit(value.isEmpty ? nil : value)
    dismiss()
  }
}
