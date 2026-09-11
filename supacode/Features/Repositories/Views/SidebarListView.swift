import ComposableArchitecture
import Sharing
import SwiftUI

// Uses LazyVStack rather than List for repository drag precision; keyboard
// worktree navigation goes through Cmd+Ctrl+↑/↓ (`selectNextWorktree`).
struct SidebarListView: View {
  enum RepositoryListHeaderAction: Equatable {
    case expandAll
    case expandActive
    case collapseAll

    var title: String {
      switch self {
      case .expandAll:
        return "Expand All"
      case .expandActive:
        return "Expand Active"
      case .collapseAll:
        return "Collapse All"
      }
    }

    var helpText: String {
      switch self {
      case .expandActive:
        return "Expand repositories with open tabs"
      case .expandAll, .collapseAll:
        return title
      }
    }

    var systemImageName: String {
      switch self {
      case .expandActive:
        return "chevron.right.2"
      case .expandAll, .collapseAll:
        return "chevron.right"
      }
    }

    var rotation: Angle {
      switch self {
      case .expandAll, .expandActive:
        return .zero
      case .collapseAll:
        return .degrees(90)
      }
    }
  }

  @Bindable var store: StoreOf<RepositoriesFeature>
  @Binding var expandedRepoIDs: Set<Repository.ID>
  @Binding var sidebarSelections: Set<SidebarSelection>
  let terminalManager: WorktreeTerminalManager
  @State private var isDragActive = false
  @State private var draggingRepositoryID: Repository.ID?
  @State private var targetedRepositoryDropDestination: Int?
  @State private var sidebarHeight = 0.0
  @State private var sidebarFooterHeight = 0.0
  @State private var resizingPanelHeight: Double?
  @State private var isAddChoicePresented = false
  @Namespace private var topSegmentNamespace
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    let state = store.state
    let hotkeyRows = state.orderedWorktreeRows(includingRepositoryIDs: expandedRepoIDs)
    let presentation = state.sidebarPresentation(expandedRepositoryIDs: expandedRepoIDs)
    let expandableRepositoryIDs = Self.expandableRepositoryIDs(in: state.repositories)
    let repositoryItems = presentation.items.filter(\.isRepositoryOrderItem)
    let selectedWorktreeIDs = Self.selectedWorktreeIDs(in: state)
    let pendingSidebarReveal = state.pendingSidebarReveal

    let maximumPanelHeight =
      sidebarHeight > 0
      ? ActiveAgentsFeature.maximumPanelHeight(forContainerHeight: sidebarHeight)
      : ActiveAgentsFeature.maximumPanelHeight
    // The Active Agents panel and its `entries` read live in
    // `SidebarActiveAgentsOverlay` so that agent-state churn re-evaluates only
    // that overlay, not this body and the repository list. This body must not
    // read `state.activeAgents.entries`.
    let panelHeight = min(resizingPanelHeight ?? state.activeAgents.panelHeight, maximumPanelHeight)
    let panelOffset = state.activeAgents.isPanelHidden ? panelHeight : 0
    let activeAgentsPanelTopGap = 4.0
    let listBottomPadding =
      state.activeAgents.isPanelHidden ? 0 : panelHeight + activeAgentsPanelTopGap

    ScrollViewReader { scrollProxy in
      ScrollView {
        // Avoid LazyVStack here: after collapsing and expanding large sections,
        // SwiftUI's lazy placement cache can spin on the main thread while scrolling.
        VStack(spacing: 0) {
          RemoteMirrorSidebar()
          // When there are no repositories the sidebar stays empty — the
          // detail pane's `EmptyStateView` ("Open a repository or folder")
          // carries the prompt and the Add button instead.
          if !repositoryItems.isEmpty {
            repositoryListHeader(
              expandableRepositoryIDs: expandableRepositoryIDs
            )
          }
          ForEach(Array(repositoryItems.enumerated()), id: \.element.id) { index, item in
            repositoryItemView(
              item,
              index: index,
              repositoryOrderIDs: presentation.repositoryOrderIDs,
              hotkeyRows: hotkeyRows,
              selectedWorktreeIDs: selectedWorktreeIDs
            )
          }
        }
        .padding(.vertical, 2)
        .padding(.bottom, listBottomPadding)
      }
      .scrollIndicators(.never)
      .frame(minWidth: 220)
      .clipped()
      .onGeometryChange(for: Double.self) { proxy in
        Double(proxy.size.height)
      } action: { newHeight in
        sidebarHeight = newHeight
      }
      .onDragSessionUpdated { session in
        if case .ended = session.phase {
          endSidebarDrag()
          return
        }
        if case .dataTransferCompleted = session.phase {
          endSidebarDrag()
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        topSegmentBar
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SidebarFooterView(store: store)
          .onGeometryChange(for: Double.self) { proxy in
            Double(proxy.size.height)
          } action: { newHeight in
            sidebarFooterHeight = newHeight
          }
          .padding(.vertical, 4)
      }
      .overlay {
        if repositoryItems.isEmpty {
          Text("Repositories you add will appear here")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            // Sit above dead-center for better visual balance in the tall panel.
            .offset(y: -40)
            .accessibilityAddTraits(.isStaticText)
        }
      }
      .overlay(alignment: .bottom) {
        SidebarActiveAgentsOverlay(
          store: store,
          terminalManager: terminalManager,
          panelHeight: panelHeight,
          maximumPanelHeight: maximumPanelHeight,
          panelOffset: panelOffset,
          isPanelHidden: state.activeAgents.isPanelHidden,
          sidebarFooterHeight: sidebarFooterHeight,
          onHeightChanged: { height in
            resizingPanelHeight = height
          },
          onHeightChangeEnded: { height in
            resizingPanelHeight = nil
            store.send(.activeAgents(.panelHeightChanged(height)))
          }
        )
      }
      .dropDestination(for: URL.self) { urls, _ in
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        store.send(.repositoryManagement(.openRepositories(fileURLs)))
        return true
      }
      .onAppear {
        resetSidebarDrag()
      }
      .task(id: pendingSidebarReveal?.id) {
        await revealPendingSidebarWorktree(pendingSidebarReveal, with: scrollProxy)
      }
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Button {
            isAddChoicePresented = true
          } label: {
            Label("Add...", systemImage: "folder.badge.plus")
          }
          .help("Add Repository or Workspace")
          .persistentPopover(isPresented: $isAddChoicePresented) {
            AddToProwlView(
              dismiss: { isAddChoicePresented = false },
              onBrowse: {
                store.send(.setOpenPanelPresented(true))
              },
              onCloneCompleted: { url in
                store.send(.repositoryManagement(.openRepositories([url])))
              },
              onWorkspace: {
                store.send(.workspaceCreation(.promptRequested))
              },
              onDrop: { urls in
                store.send(.repositoryManagement(.openRepositories(urls)))
              }
            )
          }
        }
      }
    }  // ScrollViewReader
  }

  // Fixed, opaque top bar (Xcode-navigator style): stays put while the list
  // scrolls underneath, so it neither bounces with the scroll nor lets repo
  // rows show through. Custom segmented control because the system .segmented
  // Picker only renders bare icon/text and ignores option layout, so it can't
  // be widened to fill; equal-width buttons inside a glass capsule track give
  // the macOS 26 look while truly filling the width.
  private var topSegmentBar: some View {
    HStack(spacing: 4) {
      topSegmentButton(
        .tabbed,
        systemImage: "checklist.unchecked",
        title: "Default",
        accessibilityIdentifier: "sidebar-view-mode-default"
      )
      topSegmentButton(
        .canvas,
        systemImage: "square.grid.2x2",
        title: "Canvas",
        accessibilityIdentifier: "sidebar-view-mode-canvas",
        shortcutCommandID: AppShortcuts.CommandID.toggleCanvas,
        requiresRepository: true
      )
      topSegmentButton(
        .shelf,
        systemImage: "distribute.horizontal.fill",
        title: "Shelf",
        accessibilityIdentifier: "sidebar-view-mode-shelf",
        shortcutCommandID: AppShortcuts.CommandID.toggleShelf,
        requiresRepository: true
      )
    }
    .background {
      // Glass track, brightened by the same fill the terminal tab bar's capsule
      // uses so the inactive (unselected) segments read at the same level as the
      // tab bar instead of sitting darker on the bare material.
      Capsule()
        .fill(.thinMaterial)
        .overlay(Capsule().fill(TerminalTabBarColors.barBackground))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
  }

  private func topSegmentButton(
    _ segment: TopSegment,
    systemImage: String,
    title: String,
    accessibilityIdentifier: String,
    shortcutCommandID: String? = nil,
    requiresRepository: Bool = false
  ) -> some View {
    let isSelected = store.topSegment == segment
    // Canvas and Shelf need at least one repository; with none, only Normal
    // (Default) is available, so disable them.
    let isDisabled = requiresRepository && store.repositories.isEmpty
    let helpText =
      isDisabled
      ? "\(title) — add a repository first"
      : shortcutCommandID.map {
        AppShortcuts.helpText(title: title, commandID: $0, in: resolvedKeybindings)
      } ?? title
    return Button {
      store.send(.setTopSegment(segment))
    } label: {
      Image(systemName: systemImage)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        .background {
          if isSelected {
            Capsule()
              .fill(Color.accentColor)
              .matchedGeometryEffect(id: "topSegmentPill", in: topSegmentNamespace)
          }
        }
        .contentShape(.capsule)
        .opacity(isDisabled ? 0.35 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(helpText)
    .accessibilityLabel(Text(title))
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }

  private func focusTerminalAfterSidebarSelection(worktreeID: Worktree.ID?) {
    guard let worktreeID else { return }
    Task { @MainActor [terminalManager] in
      for _ in 0..<4 {
        await Task.yield()
        if let terminalState = terminalManager.stateIfExists(for: worktreeID) {
          terminalState.focusSelectedTab()
          return
        }
      }
    }
  }

  private func repositoryListHeader(
    expandableRepositoryIDs: Set<Repository.ID>
  ) -> some View {
    HStack(spacing: 4) {
      Text("Repositories")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !expandableRepositoryIDs.isEmpty {
        RepositoryListHeaderToggle(
          repositories: store.state.repositories,
          expandableRepositoryIDs: expandableRepositoryIDs,
          expandedRepoIDs: $expandedRepoIDs,
          terminalManager: terminalManager
        )
      }
    }
    .frame(maxWidth: .infinity, minHeight: 26, alignment: .center)
    .padding(.leading, 12)
    .padding(.trailing, 7)
    .padding(.top, 2)
    .padding(.bottom, 4)
  }

  @ViewBuilder
  private func repositoryItemView(
    _ item: SidebarItem,
    index: Int,
    repositoryOrderIDs: [Repository.ID],
    hotkeyRows: [WorktreeRowModel],
    selectedWorktreeIDs: Set<Worktree.ID>
  ) -> some View {
    Group {
      switch item {
      case .repository(let model):
        if let repository = store.state.repositories[id: model.repositoryID] {
          RepositorySectionView(
            repository: repository,
            hasTopSpacing: index > 0,
            isDragActive: isDragActive,
            hotkeyRows: hotkeyRows,
            selectedWorktreeIDs: selectedWorktreeIDs,
            expandedRepoIDs: $expandedRepoIDs,
            store: store,
            terminalManager: terminalManager,
            onRepositorySelected: {
              selectRepository(repository)
            }
          )
          .draggableRepository(
            id: model.repositoryID,
            isEnabled: !model.isRemoving,
            beginDrag: {
              beginSidebarDrag(repositoryID: model.repositoryID)
            }
          )
        }

      case .failedRepository(let model):
        FailedRepositoryRow(
          name: model.name,
          path: model.path,
          showFailure: {
            let message = "\(model.path)\n\n\(model.failureMessage)"
            store.send(.presentAlert(title: "Unable to load \(model.name)", message: message))
          },
          removeRepository: {
            store.send(.repositoryManagement(.removeFailedRepository(model.id)))
          }
        )
        .padding(.horizontal, 12)
        .overlay(alignment: .top) {
          if index > 0 {
            Rectangle()
              .fill(.secondary)
              .frame(height: 1)
              .frame(maxWidth: .infinity)
              .accessibilityHidden(true)
          }
        }
        .draggableRepository(
          id: model.id,
          isEnabled: model.isReorderable,
          beginDrag: {
            beginSidebarDrag(repositoryID: model.id)
          }
        )

      case .listHeader, .archivedWorktrees:
        EmptyView()
      }
    }
    .repositoryDropTarget(
      index: index,
      repositoryOrderIDs: repositoryOrderIDs,
      isEnabled: isDragActive,
      targetedDestination: $targetedRepositoryDropDestination,
      actions: SidebarDropTargetActions(
        draggedItemID: draggingRepositoryID,
        onDrop: { offsets, destination in
          withAnimation(.easeOut(duration: 0.2)) {
            _ = store.send(.worktreeOrdering(.repositoriesMoved(offsets, destination)))
          }
        },
        onDragEnded: endSidebarDrag
      )
    )
  }

  private func beginSidebarDrag(repositoryID: Repository.ID) {
    guard !isDragActive else { return }
    draggingRepositoryID = repositoryID
    isDragActive = true
    store.send(.worktreeOrdering(.setSidebarDragActive(true)))
  }

  private func endSidebarDrag() {
    targetedRepositoryDropDestination = nil
    draggingRepositoryID = nil
    isDragActive = false
    store.send(.worktreeOrdering(.setSidebarDragActive(false)))
  }

  private func resetSidebarDrag() {
    targetedRepositoryDropDestination = nil
    draggingRepositoryID = nil
    isDragActive = false
    store.send(.worktreeOrdering(.setSidebarDragActive(false)))
  }

  private func selectRepository(_ repository: Repository) {
    if repository.capabilities.supportsWorktrees {
      withAnimation(.easeOut(duration: 0.2)) {
        if expandedRepoIDs.contains(repository.id) {
          expandedRepoIDs.remove(repository.id)
        } else {
          expandedRepoIDs.insert(repository.id)
        }
      }
      sidebarSelections = []
    } else {
      sidebarSelections = [.repository(repository.id)]
      if store.state.isShowingCanvas, Self.repositoryHeaderOpensCanvasTarget(repository) {
        store.send(.focusCanvasRepository(repository.id))
      } else {
        store.send(.selectRepository(repository.id))
        focusTerminalAfterSidebarSelection(worktreeID: store.state.selectedTerminalWorktree?.id)
      }
    }
  }

  @MainActor
  private func revealPendingSidebarWorktree(
    _ pendingSidebarReveal: PendingSidebarReveal?,
    with scrollProxy: ScrollViewProxy
  ) async {
    guard let pendingSidebarReveal else { return }
    // Give SwiftUI time to materialize newly expanded section rows before scrolling.
    await Task.yield()
    await Task.yield()
    withAnimation(.easeOut(duration: 0.2)) {
      scrollProxy.scrollTo(
        SidebarScrollID.worktree(pendingSidebarReveal.worktreeID), anchor: .center)
    }
    store.send(.consumePendingSidebarReveal(pendingSidebarReveal.id))
  }

  static func expandableRepositoryIDs<Repositories: Sequence>(
    in repositories: Repositories
  ) -> Set<Repository.ID> where Repositories.Element == Repository {
    Set(
      repositories
        .filter { $0.capabilities.supportsWorktrees || $0.isWorkspace }
        .map(\.id)
    )
  }

  /// Expandable repositories/workspaces with at least one open terminal tab.
  static func activeRepositoryIDs<Repositories: Sequence>(
    in repositories: Repositories,
    expandableRepositoryIDs: Set<Repository.ID>,
    terminalManager: WorktreeTerminalManager
  ) -> Set<Repository.ID> where Repositories.Element == Repository {
    Set(
      repositories
        .filter { expandableRepositoryIDs.contains($0.id) }
        .filter {
          RepositorySectionView.openTabCount(for: $0, terminalManager: terminalManager) > 0
        }
        .map(\.id)
    )
  }

  /// Next action offered by the header toggle, derived purely from the
  /// current expansion state (no stored mode). Cycle from fully collapsed:
  /// Expand Active → Expand All → Collapse All. Expand Active is skipped
  /// when the active set is empty or covers every expandable repository,
  /// and any manually mixed state falls back to Collapse All.
  static func repositoryListHeaderAction(
    expandedRepoIDs: Set<Repository.ID>,
    expandableRepositoryIDs: Set<Repository.ID>,
    activeRepositoryIDs: Set<Repository.ID>
  ) -> RepositoryListHeaderAction {
    let expanded = expandedRepoIDs.intersection(expandableRepositoryIDs)
    let active = activeRepositoryIDs.intersection(expandableRepositoryIDs)
    let activeIsProperSubset = !active.isEmpty && active != expandableRepositoryIDs
    if expanded.isEmpty {
      return activeIsProperSubset ? .expandActive : .expandAll
    }
    if activeIsProperSubset, expanded == active {
      return .expandAll
    }
    return .collapseAll
  }

  static func selectedWorktreeIDs(in state: RepositoriesFeature.State) -> Set<Worktree.ID> {
    var selectedWorktreeIDs = state.sidebarSelectedWorktreeIDs
    if let selectedWorktreeID = state.selectedWorktreeID {
      selectedWorktreeIDs.insert(selectedWorktreeID)
    }
    return selectedWorktreeIDs
  }

  static func repositoryHeaderOpensCanvasTarget(_ repository: Repository) -> Bool {
    repository.capabilities.supportsRunnableFolderActions
      && !repository.capabilities.supportsWorktrees
  }

  static func activeAgentWorktreeMetadata(
    repositories: IdentifiedArrayOf<Repository>,
    customTitles: [Repository.ID: String],
    repositoryAppearances: [Repository.ID: RepositoryAppearance] = [:]
  ) -> ActiveAgentWorktreeMetadata {
    var repositoryNamesByWorktreeID: [Worktree.ID: String] = [:]
    var branchNamesByWorktreeID: [Worktree.ID: String] = [:]
    var repositoryColorsByWorktreeID: [Worktree.ID: RepositoryColorChoice] = [:]

    for repository in repositories {
      let repositoryName = customTitles[repository.id] ?? repository.name
      let repositoryColor = repositoryAppearances[repository.id]?.color
      if repository.capabilities.supportsRunnableFolderActions
        && !repository.capabilities.supportsWorktrees
      {
        repositoryNamesByWorktreeID[repository.id] = repositoryName
        branchNamesByWorktreeID[repository.id] = repository.name
        if let repositoryColor {
          repositoryColorsByWorktreeID[repository.id] = repositoryColor
        }
      }
      for worktree in repository.worktrees {
        repositoryNamesByWorktreeID[worktree.id] = repositoryName
        branchNamesByWorktreeID[worktree.id] = worktree.name
        if let repositoryColor {
          repositoryColorsByWorktreeID[worktree.id] = repositoryColor
        }
      }
    }

    return ActiveAgentWorktreeMetadata(
      repositoryNamesByWorktreeID: repositoryNamesByWorktreeID,
      branchNamesByWorktreeID: branchNamesByWorktreeID,
      repositoryColorsByWorktreeID: repositoryColorsByWorktreeID
    )
  }

  /// Resolves the repository/branch label shown for each active agent from the directory the
  /// agent actually runs in, rather than the tab's owning worktree.
  static func activeAgentRowDisplays(
    entries: IdentifiedArrayOf<ActiveAgentEntry>,
    repositories: IdentifiedArrayOf<Repository>,
    metadata: ActiveAgentWorktreeMetadata
  ) -> [ActiveAgentEntry.ID: ActiveAgentRowDisplay] {
    // Resolutions are memoized across renders, not just shared within this batch. The index made
    // the *build* side cheap; the lookup still normalizes the queried directory, and that
    // normalization is a filesystem round-trip. This view re-runs whenever an agent's state
    // changes, so re-resolving unchanged directories put N `stat`s plus N symlink walks on the
    // main thread per frame.
    let resolvedWorktreeIDs = WorktreeDirectoryIndexCache.worktreeIDs(
      forWorkingDirectories: entries.compactMap(\.workingDirectory),
      in: repositories
    )
    var displays: [ActiveAgentEntry.ID: ActiveAgentRowDisplay] = [:]
    for entry in entries {
      let resolvedWorktreeID = entry.workingDirectory.flatMap { resolvedWorktreeIDs[$0] }
      displays[entry.id] = activeAgentRowDisplay(
        for: entry,
        repositories: repositories,
        metadata: metadata,
        resolvedWorktreeID: resolvedWorktreeID
      )
    }
    return displays
  }

  /// Three-tier resolution for the displayed name/branch of a single agent:
  /// 1. `workingDirectory` falls inside a known repo/worktree → use it, so the label tracks live
  ///    branch renames through `metadata`.
  /// 2. `workingDirectory` is known but outside every repo → derive a name from its last path
  ///    component (same logic as adding a repository).
  /// 3. `workingDirectory` is unknown → fall back to the surface's owning worktree (legacy behavior).
  /// `directoryIndex` resolves the entry's working directory; passing `nil` builds a throwaway
  /// index for the single lookup. `activeAgentRowDisplays` does not come through here — it resolves
  /// through the memo in `WorktreeDirectoryIndexCache` and calls the `resolvedWorktreeID` overload.
  static func activeAgentRowDisplay(
    for entry: ActiveAgentEntry,
    repositories: IdentifiedArrayOf<Repository>,
    metadata: ActiveAgentWorktreeMetadata,
    directoryIndex: WorktreeDirectoryIndex? = nil
  ) -> ActiveAgentRowDisplay {
    let resolvedWorktreeID = entry.workingDirectory.flatMap { workingDirectory in
      (directoryIndex ?? WorktreeDirectoryIndex(repositories: repositories))
        .worktreeID(forWorkingDirectory: workingDirectory)
    }
    return activeAgentRowDisplay(
      for: entry,
      repositories: repositories,
      metadata: metadata,
      resolvedWorktreeID: resolvedWorktreeID
    )
  }

  /// Builds the display from an already-resolved owning worktree, so a caller that resolves in
  /// bulk pays the directory normalization once per directory instead of once per row.
  static func activeAgentRowDisplay(
    for entry: ActiveAgentEntry,
    repositories: IdentifiedArrayOf<Repository>,
    metadata: ActiveAgentWorktreeMetadata,
    resolvedWorktreeID: Worktree.ID?
  ) -> ActiveAgentRowDisplay {
    if let workingDirectory = entry.workingDirectory {
      if let key = resolvedWorktreeID {
        let fallbackName = workingDirectory.lastPathComponent
        return ActiveAgentRowDisplay(
          repositoryName: metadata.repositoryNamesByWorktreeID[key] ?? fallbackName,
          branchName: metadata.branchNamesByWorktreeID[key] ?? fallbackName,
          color: metadata.repositoryColorsByWorktreeID[key],
          directory: workingDirectory
        )
      }
      let name = Repository.name(for: workingDirectory)
      return ActiveAgentRowDisplay(
        repositoryName: name,
        branchName: name,
        color: nil,
        directory: workingDirectory
      )
    }
    return ActiveAgentRowDisplay(
      repositoryName: metadata.repositoryNamesByWorktreeID[entry.worktreeID] ?? entry.worktreeName,
      branchName: metadata.branchNamesByWorktreeID[entry.worktreeID] ?? entry.worktreeName,
      color: metadata.repositoryColorsByWorktreeID[entry.worktreeID],
      directory: directory(forWorktreeID: entry.worktreeID, in: repositories)
    )
  }

  /// Finds the most specific repo/worktree whose directory contains `workingDirectory`. Plain
  /// folders are keyed by their repository id (matching `activeAgentWorktreeMetadata`); git repos
  /// are matched through their worktrees (the main worktree covers the repo root). When nested
  /// directories both match (e.g. a worktree inside a repo), the deepest one wins.
  static func resolveWorktreeID(
    forWorkingDirectory workingDirectory: URL,
    in repositories: IdentifiedArrayOf<Repository>
  ) -> Worktree.ID? {
    WorktreeDirectoryIndex(repositories: repositories)
      .worktreeID(forWorkingDirectory: workingDirectory)
  }

  /// Directory of the surface's owning worktree, used when the agent hasn't
  /// reported a working directory. Plain folders are keyed by repository id.
  static func directory(
    forWorktreeID worktreeID: Worktree.ID,
    in repositories: IdentifiedArrayOf<Repository>
  ) -> URL? {
    for repository in repositories {
      if let worktree = repository.worktrees[id: worktreeID] {
        return worktree.workingDirectory
      }
    }
    guard let repository = repositories[id: worktreeID],
      repository.capabilities.supportsRunnableFolderActions
    else { return nil }
    return repository.rootURL
  }
}

/// Header expand/collapse toggle as its own leaf view: deriving the offered
/// action needs per-repository open-tab counts, and this split keeps the
/// `WorktreeTerminalManager` read out of `SidebarListView.body` (same
/// isolation rationale as `RepoHeaderTabCountBadge`).
private struct RepositoryListHeaderToggle: View {
  let repositories: IdentifiedArrayOf<Repository>
  let expandableRepositoryIDs: Set<Repository.ID>
  @Binding var expandedRepoIDs: Set<Repository.ID>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    let activeRepositoryIDs = SidebarListView.activeRepositoryIDs(
      in: repositories,
      expandableRepositoryIDs: expandableRepositoryIDs,
      terminalManager: terminalManager
    )
    let action = SidebarListView.repositoryListHeaderAction(
      expandedRepoIDs: expandedRepoIDs,
      expandableRepositoryIDs: expandableRepositoryIDs,
      activeRepositoryIDs: activeRepositoryIDs
    )
    Button {
      withAnimation(.easeOut(duration: 0.2)) {
        switch action {
        case .expandAll:
          expandedRepoIDs.formUnion(expandableRepositoryIDs)
        case .expandActive:
          var next = expandedRepoIDs
          next.subtract(expandableRepositoryIDs)
          next.formUnion(activeRepositoryIDs)
          expandedRepoIDs = next
        case .collapseAll:
          expandedRepoIDs.subtract(expandableRepositoryIDs)
        }
      }
    } label: {
      Label(action.title, systemImage: action.systemImageName)
        .labelStyle(.iconOnly)
        .frame(width: 20, height: 20)
        .rotationEffect(action.rotation)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(action.helpText)
  }
}

struct ActiveAgentWorktreeMetadata: Equatable {
  let repositoryNamesByWorktreeID: [Worktree.ID: String]
  let branchNamesByWorktreeID: [Worktree.ID: String]
  let repositoryColorsByWorktreeID: [Worktree.ID: RepositoryColorChoice]
}

struct ActiveAgentRowDisplay: Equatable {
  let repositoryName: String
  let branchName: String
  let color: RepositoryColorChoice?
  /// The directory the agent runs in (or its owning worktree's directory as a
  /// fallback); drives the context menu's Copy Path / Reveal in Finder.
  let directory: URL?
}

extension SidebarItem {
  fileprivate var isRepositoryOrderItem: Bool {
    repositoryOrderID != nil
  }
}

// MARK: - Previews

#if DEBUG
  @MainActor
  private struct SidebarLayoutPreview: View {
    @State private var expandedRepoIDs: Set<Repository.ID>
    @State private var sidebarSelections: Set<SidebarSelection> = []
    private let store: StoreOf<RepositoriesFeature>
    private let terminalManager: WorktreeTerminalManager = .preview

    init() {
      let state = Self.mockState
      _expandedRepoIDs = State(initialValue: Set(state.repositories.map(\.id)))
      store = Store(initialState: state) { EmptyReducer() }
    }

    var body: some View {
      SidebarListView(
        store: store,
        expandedRepoIDs: $expandedRepoIDs,
        sidebarSelections: $sidebarSelections,
        terminalManager: terminalManager
      )
      .environment(CommandKeyObserver())
      .frame(width: 320, height: 500)
    }

    private static var mockState: RepositoriesFeature.State {
      let repo1Root = URL(fileURLWithPath: "/tmp/supacode")
      let repo1Worktrees: IdentifiedArrayOf<Worktree> = [
        Worktree(
          id: repo1Root.path, name: "main", detail: ".",
          workingDirectory: repo1Root, repositoryRootURL: repo1Root
        ),
        Worktree(
          id: "/tmp/wt/sidebar", name: "feature/sidebar-redesign", detail: "/tmp/wt/sidebar",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/sidebar"), repositoryRootURL: repo1Root
        ),
        Worktree(
          id: "/tmp/wt/auth", name: "feature/auth", detail: "/tmp/wt/auth",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/auth"), repositoryRootURL: repo1Root
        ),
        Worktree(
          id: "/tmp/wt/crash", name: "fix/crash", detail: "/tmp/wt/crash",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/crash"), repositoryRootURL: repo1Root
        ),
      ]
      let repo1 = Repository(
        id: repo1Root.path, rootURL: repo1Root, name: "supacode", worktrees: repo1Worktrees
      )

      let repo2Root = URL(fileURLWithPath: "/tmp/ghostty")
      let repo2Worktrees: IdentifiedArrayOf<Worktree> = [
        Worktree(
          id: repo2Root.path, name: "main", detail: ".",
          workingDirectory: repo2Root, repositoryRootURL: repo2Root
        ),
        Worktree(
          id: "/tmp/wt/renderer", name: "feature/renderer", detail: "/tmp/wt/renderer",
          workingDirectory: URL(fileURLWithPath: "/tmp/wt/renderer"), repositoryRootURL: repo2Root
        ),
      ]
      let repo2 = Repository(
        id: repo2Root.path, rootURL: repo2Root, name: "ghostty", worktrees: repo2Worktrees
      )

      var state = RepositoriesFeature.State()
      state.repositories = [repo1, repo2]
      state.pinnedWorktreeIDs = ["/tmp/wt/auth"]
      state.worktreeInfoByID = [
        "/tmp/wt/sidebar": WorktreeInfoEntry(addedLines: 120, removedLines: 45, pullRequest: nil)
      ]
      return state
    }
  }

  #Preview("Sidebar Layout") {
    SidebarLayoutPreview()
  }
#endif
