import ComposableArchitecture
import Observation
import Sharing
import SwiftUI

@MainActor
@Observable
final class AgentIslandPresentationModel {
  var notchSize: CGSize?
  var floatingMenuBarHeight: CGFloat?
}

enum AgentIslandFloatingDragEvent {
  case began(pointerX: CGFloat)
  case changed(pointerX: CGFloat)
  case ended(pointerX: CGFloat)
}

struct AgentIslandRootLayout {
  static let floatingCompactWidth: CGFloat = 340
  static let fallbackFloatingCompactHeight: CGFloat = 40
  static let rosterWidth: CGFloat = 420

  static func width(
    notchCompactWidth: CGFloat?,
    isRosterExpanded: Bool,
    attentionEntryCount: Int
  ) -> CGFloat {
    let compactWidth = notchCompactWidth ?? floatingCompactWidth
    if isRosterExpanded {
      return max(compactWidth, rosterWidth)
    }
    guard attentionEntryCount > 0 else { return compactWidth }
    let attentionWidth = AgentIslandAttentionLayout.layout(entryCount: attentionEntryCount).width
    return max(compactWidth, attentionWidth)
  }

  static func compactHeight(
    notchCompactHeight: CGFloat?,
    floatingMenuBarHeight: CGFloat?
  ) -> CGFloat {
    if let notchCompactHeight {
      return notchCompactHeight
    }
    guard let floatingMenuBarHeight, floatingMenuBarHeight > 0 else {
      return fallbackFloatingCompactHeight
    }
    return floatingMenuBarHeight
  }

  static func showsDisplayControl(connectedDisplayCount: Int) -> Bool {
    connectedDisplayCount > 1
  }

  static func usesCompactFloatingSummary(stateCount: Int) -> Bool {
    stateCount >= AgentIslandStateSummary.order.count
  }
}

struct AgentIslandView: View {
  @Bindable private var appStore: StoreOf<AppFeature>
  @Bindable private var agentsStore: StoreOf<ActiveAgentsFeature>
  @Bindable private var presentation: AgentIslandPresentationModel
  private let terminalManager: WorktreeTerminalManager
  @Shared(.repositoryAppearances) private var repositoryAppearances
  @State private var displayCatalog = AgentIslandDisplayCatalog.shared

  let presentationChanged: (Bool, Bool, AgentIslandDisplayPreference, CGSize) -> Void
  let floatingDragChanged: (AgentIslandFloatingDragEvent) -> Void
  @State private var contentSize = CGSize(width: 420, height: 40)
  @State private var isHovering = false
  @State private var isSilent = false
  @State private var isBarHovered = false
  @State private var isFloatingDragging = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    store: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager,
    presentation: AgentIslandPresentationModel,
    presentationChanged: @escaping (Bool, Bool, AgentIslandDisplayPreference, CGSize) -> Void,
    floatingDragChanged: @escaping (AgentIslandFloatingDragEvent) -> Void
  ) {
    appStore = store
    agentsStore = store.scope(
      state: \.repositories.activeAgents,
      action: \.repositories.activeAgents
    )
    self.terminalManager = terminalManager
    self.presentation = presentation
    self.presentationChanged = presentationChanged
    self.floatingDragChanged = floatingDragChanged
  }

  var body: some View {
    Group {
      if isVisible {
        islandContent
      } else {
        Color.clear
          .frame(width: 1, height: 1)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self) { proxy in
      proxy.size
    } action: { newSize in
      guard isVisible else { return }
      contentSize = newSize
      publishPresentation(size: newSize)
    }
    .onChange(of: isVisible, initial: true) { _, _ in
      publishPresentation()
    }
    .onChange(of: agentsStore.isIslandRosterExpanded, initial: true) { _, _ in
      publishPresentation()
    }
    .onChange(of: appStore.settings.agentIslandDisplayPreference, initial: true) { _, _ in
      publishPresentation()
    }
    // The panel is resized to fit after SwiftUI has laid out the new content. Without an explicit
    // top alignment the hosting view centers the content vertically, so for that one pass a taller
    // or shorter island is offset from the top edge and every animated child springs back into
    // place once the frame catches up. Pinning to the top keeps the compact bar at y = 0 throughout.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .preferredColorScheme(.dark)
  }

  private var islandContent: some View {
    VStack(spacing: 6) {
      compactIsland
      if agentsStore.isIslandRosterExpanded {
        rosterIsland
      } else if !agentsStore.islandAttentionEntries.isEmpty {
        AgentIslandAttentionCollection(
          entries: agentsStore.islandAttentionEntries,
          rowDisplays: rowDisplays,
          workflowBadges: appStore.repositories.workflowRoleBadgesBySurfaceID,
          showTabTitles: appStore.repositories.showActiveAgentTabTitles,
          onTap: { agentsStore.send(.island(.entryTapped($0))) }
        )
      }
    }
    .frame(width: rootWidth)
    // Keep the opacity animation outside a transaction-free content subtree. Otherwise, when
    // `isSilent` clears in the same update that opens the roster, SwiftUI also animates the
    // roster's layout from the compact panel and its footer briefly crosses the floating bar.
    .transaction { transaction in
      transaction.animation = nil
    }
    .opacity(
      AgentIslandOpacityPolicy.opacity(
        isFloating: isFloating,
        isSilent: isSilent,
        isRosterExpanded: agentsStore.isIslandRosterExpanded,
        hasAttentionEntries: !agentsStore.islandAttentionEntries.isEmpty,
        silentOpacity: appStore.settings.agentIslandSilentOpacity
      )
    )
    .animation(.easeOut(duration: 0.2), value: isSilent)
    .onHover { isHovering = $0 }
    .task(id: shouldEnterSilentState) {
      guard shouldEnterSilentState else {
        isSilent = false
        return
      }
      do {
        try await Task.sleep(for: AgentIslandOpacityPolicy.silenceDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      isSilent = true
    }
  }

  private var compactIsland: some View {
    Button {
      agentsStore.send(.islandToggleRoster)
    } label: {
      Group {
        if let notchLayout {
          notchedCompactContent(layout: notchLayout)
        } else {
          HStack(spacing: 9) {
            compactContent
            compactChevron
          }
          .padding(.horizontal, 14)
          .frame(width: AgentIslandRootLayout.floatingCompactWidth, height: compactHeight)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(.black, in: compactShape)
    .overlay(alignment: .leading) {
      if isFloating {
        floatingDragHandle
          .padding(.leading, 14)
          .opacity(showsFloatingGrip ? 1 : 0)
          .allowsHitTesting(showsFloatingGrip)
          .animation(gripAnimation, value: showsFloatingGrip)
      }
    }
    .onHover { isBarHovered = $0 }
    .accessibilityLabel(
      agentsStore.isIslandRosterExpanded ? "Hide Active Agents" : "Show Active Agents"
    )
    .accessibilityIdentifier("agent-island-compact")
  }

  private var floatingDragHandle: some View {
    ZStack {
      Image(systemName: "line.3.horizontal")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      AgentIslandDragCaptureView { event in
        switch event {
        case .began:
          isFloatingDragging = true
        case .ended:
          isFloatingDragging = false
        case .changed:
          break
        }
        floatingDragChanged(event)
      }
    }
    .frame(width: 24, height: 20)
    .accessibilityHidden(true)
  }

  private var showsFloatingGrip: Bool { isBarHovered || isFloatingDragging }

  private var gripAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.18)
  }

  private func notchedCompactContent(layout: AgentIslandNotchLayout) -> some View {
    HStack(spacing: 0) {
      notchedLeadingContent
        .padding(.leading, 12)
        .frame(width: layout.wingWidth, alignment: .leading)
      Color.clear
        .frame(width: layout.cutoutSize.width)
        .accessibilityHidden(true)
      notchedTrailingContent
        .padding(.trailing, 12)
        .frame(width: layout.wingWidth, alignment: .trailing)
    }
    .frame(width: layout.compactWidth, height: layout.compactHeight)
  }

  private var notchedLeadingContent: some View {
    AgentIslandStateSummaryView(summary: stateSummary, size: .compact)
  }

  private var notchedTrailingContent: some View {
    HStack(spacing: 5) {
      AgentIslandIconCluster(entries: islandEntries, pointSize: 20)
      compactChevron
    }
  }

  private var compactChevron: some View {
    Image(systemName: agentsStore.isIslandRosterExpanded ? "chevron.up" : "chevron.down")
      .font(.caption2.weight(.bold))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  /// The floating pill shows the same per-state counts as the notched wing, one size up.
  private var compactContent: some View {
    HStack(spacing: 0) {
      AgentIslandStateSummaryView(summary: stateSummary, size: floatingSummarySize)
        .offset(x: showsFloatingGrip ? 28 : 0)
        .animation(gripAnimation, value: showsFloatingGrip)
        .frame(maxWidth: .infinity, alignment: .leading)
      AgentIslandIconCluster(entries: islandEntries)
    }
  }

  private var floatingSummarySize: AgentIslandStateSummaryView.Size {
    AgentIslandRootLayout.usesCompactFloatingSummary(stateCount: stateSummary.items.count)
      ? .compact : .regular
  }

  private var stateSummary: AgentIslandStateSummary {
    AgentIslandStateSummary(entries: islandEntries)
  }

  /// Same source as the sidebar overlay: the terminal manager's active surface for the selected
  /// worktree. The reducer's `focusedSurfaceID` is a keyboard-navigation anchor fed by
  /// per-worktree deduplicated `focusChanged` events, so re-selecting a worktree leaves it
  /// pointing at the previously selected worktree's pane.
  private var selectedSurfaceID: UUID? {
    terminalManager.selectedWorktreeID.flatMap { worktreeID in
      terminalManager.stateIfExists(for: worktreeID)?.activeSurfaceID
    }
  }

  private var rosterIsland: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Active Agents")
          .font(.headline)
        Spacer()
        Button {
          agentsStore.send(.islandOpenProwlTapped)
        } label: {
          Label("Open Prowl", systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("agent-island-open-prowl")
      }
      .padding(.horizontal, 14)
      .frame(height: 44)
      .overlay {
        if AgentIslandRootLayout.showsDisplayControl(
          connectedDisplayCount: displayCatalog.screens.count
        ) {
          displayMenu
        }
      }

      Divider()

      AgentIslandRosterContent(
        store: agentsStore,
        rowDisplays: rowDisplays,
        workflowBadges: appStore.repositories.workflowRoleBadgesBySurfaceID,
        selectedSurfaceID: selectedSurfaceID
      )
    }
    // Same width as the bar above it: the notched bar is wider than the floating roster.
    .frame(width: rootWidth)
    .background(.black, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.separator.opacity(0.55), lineWidth: 1)
    }
    .accessibilityIdentifier("agent-island-roster")
  }

  private var rowDisplays: [ActiveAgentEntry.ID: ActiveAgentRowDisplay] {
    let repositories = appStore.repositories.repositories
    let metadata = SidebarListView.activeAgentWorktreeMetadata(
      repositories: repositories,
      customTitles: appStore.repositories.repositoryCustomTitles,
      repositoryAppearances: repositoryAppearances
    )
    return SidebarListView.activeAgentRowDisplays(
      entries: agentsStore.entries,
      repositories: repositories,
      metadata: metadata
    )
  }

  private var islandEntries: [ActiveAgentEntry] {
    Array(agentsStore.entries)
  }

  private var compactShape: AnyShape {
    AnyShape(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 12,
        bottomTrailingRadius: 12,
        topTrailingRadius: 0
      )
    )
  }

  private var displayMenu: some View {
    Menu {
      Button {
        setDisplayPreference(.automatic)
      } label: {
        displayMenuLabel(
          "Automatic", isSelected: appStore.settings.agentIslandDisplayPreference == .automatic)
      }
      Divider()
      ForEach(displayCatalog.screens) { screen in
        Button {
          setDisplayPreference(.display(id: screen.id, name: screen.name))
        } label: {
          displayMenuLabel(screen.name, isSelected: isSelectedDisplay(screen.id))
        }
      }
    } label: {
      Image(systemName: "display.2")
        .frame(width: 24, height: 24)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Agent Island display")
  }

  @ViewBuilder
  private func displayMenuLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private func isSelectedDisplay(_ id: String) -> Bool {
    guard case .display(let selectedID, _) = appStore.settings.agentIslandDisplayPreference else {
      return false
    }
    return selectedID == id
  }

  private func setDisplayPreference(_ preference: AgentIslandDisplayPreference) {
    appStore.send(.settings(.setAgentIslandDisplayPreference(preference)))
  }

  private var notchLayout: AgentIslandNotchLayout? {
    presentation.notchSize.map { AgentIslandNotchLayout(cutoutSize: $0) }
  }

  private var compactHeight: CGFloat {
    AgentIslandRootLayout.compactHeight(
      notchCompactHeight: notchLayout?.compactHeight,
      floatingMenuBarHeight: presentation.floatingMenuBarHeight
    )
  }

  private var isFloating: Bool { notchLayout == nil }

  private var shouldEnterSilentState: Bool {
    AgentIslandOpacityPolicy.shouldEnterSilentState(
      isFloating: isFloating,
      isRosterExpanded: agentsStore.isIslandRosterExpanded,
      hasAttentionEntries: !agentsStore.islandAttentionEntries.isEmpty,
      isHovering: isHovering,
      isControlPresented: isFloatingDragging
    )
  }

  private var rootWidth: CGFloat {
    AgentIslandRootLayout.width(
      notchCompactWidth: notchLayout?.compactWidth,
      isRosterExpanded: agentsStore.isIslandRosterExpanded,
      attentionEntryCount: agentsStore.islandAttentionEntries.count
    )
  }

  private var isVisible: Bool {
    appStore.settings.agentIslandEnabled && !agentsStore.entries.isEmpty
  }

  private func publishPresentation(size: CGSize? = nil) {
    presentationChanged(
      isVisible,
      agentsStore.isIslandRosterExpanded,
      appStore.settings.agentIslandDisplayPreference,
      size ?? contentSize
    )
  }
}

private struct AgentIslandDragCaptureView: NSViewRepresentable {
  let dragChanged: (AgentIslandFloatingDragEvent) -> Void

  func makeNSView(context: Context) -> AgentIslandDragCaptureNSView {
    AgentIslandDragCaptureNSView(dragChanged: dragChanged)
  }

  func updateNSView(_ nsView: AgentIslandDragCaptureNSView, context: Context) {
    nsView.dragChanged = dragChanged
  }
}

private final class AgentIslandDragCaptureNSView: NSView {
  var dragChanged: (AgentIslandFloatingDragEvent) -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isDragging = false

  init(dragChanged: @escaping (AgentIslandFloatingDragEvent) -> Void) {
    self.dragChanged = dragChanged
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    super.updateTrackingAreas()

    let hoverTrackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(hoverTrackingArea)
    self.hoverTrackingArea = hoverTrackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    currentDragCursor.set()
  }

  override func mouseExited(with event: NSEvent) {
    if !isDragging {
      NSCursor.arrow.set()
    }
  }

  override func cursorUpdate(with event: NSEvent) {
    currentDragCursor.set()
  }

  override func mouseDown(with event: NSEvent) {
    isDragging = true
    window?.invalidateCursorRects(for: self)
    currentDragCursor.set()
    dragChanged(.began(pointerX: NSEvent.mouseLocation.x))
  }

  override func mouseDragged(with event: NSEvent) {
    currentDragCursor.set()
    dragChanged(.changed(pointerX: NSEvent.mouseLocation.x))
  }

  override func mouseUp(with event: NSEvent) {
    isDragging = false
    window?.invalidateCursorRects(for: self)
    let pointer = convert(event.locationInWindow, from: nil)
    (bounds.contains(pointer) ? NSCursor.openHand : .arrow).set()
    dragChanged(.ended(pointerX: NSEvent.mouseLocation.x))
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: currentDragCursor)
  }

  private var currentDragCursor: NSCursor {
    isDragging ? .closedHand : .openHand
  }
}
