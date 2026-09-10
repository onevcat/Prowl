import AppKit
import ComposableArchitecture
import ProwlCLIShared
import Sharing
import SwiftUI

struct WorktreeDetailView: View {
  private struct ToolbarSharedStateInput {
    let repositories: RepositoriesFeature.State
    let workflowRuns: WorkflowRunsFeature.State
    let actionTargetWorktree: Worktree?
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let runScriptEnabled: Bool
    let runScriptIsRunning: Bool
    let customCommands: [EffectiveCustomCommand]
    let isUpdateAvailable: Bool
    let isUpdateReadyToInstall: Bool
    let availableUpdateVersion: String?
    let showRunButtonInToolbar: Bool
  }

  @Bindable var store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  /// Drive the chrome (nav + toolbar) tint for Normal and Canvas modes.
  @Shared(.repositoryAppearances) private var repositoryAppearances
  @Shared(.settingsFile) private var settingsFile
  /// True while a Canvas card is expanded in place, so the otherwise-transparent
  /// Canvas toolbar gets a matching material scrim instead of showing through.
  @State private var isCanvasCardExpanded = false
  @State private var toolbarPopovers = ToolbarPopoverCoordinator()
  @State private var historyStore = Store(initialState: WorkflowStepHistoryFeature.State()) {
    WorkflowStepHistoryFeature()
  }

  var body: some View {
    detailBody(state: store.state)
  }

  private func detailBody(state: AppFeature.State) -> some View {
    let repositories = state.repositories
    let selectedRow = repositories.selectedRow(for: repositories.selectedWorktreeID)
    let selectedWorktree = repositories.worktree(for: repositories.selectedWorktreeID)
    let selectedTerminalWorktree = repositories.selectedTerminalWorktree
    let canvasFocusedTerminalWorktree = canvasFocusedTerminalWorktree(repositories: repositories)
    let actionTargetWorktree = selectedTerminalWorktree ?? canvasFocusedTerminalWorktree
    let historyContext = workflowHistoryContext(worktree: actionTargetWorktree, repositories: repositories)
    let selectedWorktreeSummaries = selectedWorktreeSummaries(from: repositories)
    let showsMultiSelectionSummary = shouldShowMultiSelectionSummary(
      repositories: repositories,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    )
    let loadingInfo = loadingInfo(
      for: selectedRow,
      selectedWorktreeID: repositories.selectedWorktreeID,
      repositories: repositories
    )
    let hasActiveTerminalTarget =
      actionTargetWorktree != nil
      && loadingInfo == nil
      && !showsMultiSelectionSummary
    let runScriptEnabled = hasActiveTerminalTarget
    let runScriptIsRunning =
      actionTargetWorktree.flatMap { state.runScriptStatusByWorktreeID[$0.id] } == true
    let customCommands = state.selectedCustomCommands
    let notificationGroups = repositories.toolbarNotificationGroups(
      terminalManager: terminalManager,
      customTitles: repositories.repositoryCustomTitles
    )
    let unseenNotificationWorktreeCount = notificationGroups.reduce(0) { count, repository in
      count + repository.unseenWorktreeCount
    }
    let sharedToolbarState = toolbarSharedState(
      input: ToolbarSharedStateInput(
        repositories: repositories,
        workflowRuns: state.workflowRuns,
        actionTargetWorktree: actionTargetWorktree,
        notificationGroups: notificationGroups,
        unseenNotificationWorktreeCount: unseenNotificationWorktreeCount,
        runScriptEnabled: runScriptEnabled,
        runScriptIsRunning: runScriptIsRunning,
        customCommands: customCommands,
        isUpdateAvailable: state.updates.isUpdateAvailable,
        isUpdateReadyToInstall: state.updates.isUpdateReadyToInstall,
        availableUpdateVersion: state.updates.availableVersion,
        showRunButtonInToolbar: settingsFile.global.showRunButtonInToolbar
      )
    )
    let content = detailContent(
      repositories: repositories,
      loadingInfo: loadingInfo,
      selectedWorktree: selectedWorktree,
      selectedTerminalWorktree: selectedTerminalWorktree,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    )
    .navigationTitle(
      WindowTitle.compute(repositories: repositories, terminalManager: terminalManager)
    )
    .toolbar(removing: .title)
    .toolbar {
      if repositories.isShowingCanvas {
        canvasToolbarContent(state: sharedToolbarState)
      } else if hasActiveTerminalTarget {
        worktreeToolbarContent(
          toolbarState: WorktreeToolbarState(
            shared: sharedToolbarState,
            openActionSelection: state.openActionSelection,
            openActionIsAutomatic: state.openActionIsAutomatic,
            showExtras: commandKeyObserver.isPressed,
            showDefaultEditorInToolbar: settingsFile.global.showDefaultEditorInToolbar
          ),
          actionTargetWorktree: actionTargetWorktree
        )
      }
    }
    .environment(historyStore)
    .environment(toolbarPopovers)
    .task { loadWorkflowHistory(context: historyContext, runs: state.workflowRuns.sessions.values.map(\.run)) }
    .onChange(of: historyContext) { _, context in historyStore.send(.context(context)) }
    .onChange(of: state.workflowRuns.sessions) { _, sessions in
      historyStore.send(.liveRuns(sessions.values.map(\.run)))
    }
    .windowToolbarChromeBackground(
      toolbarChromeFill(repositories: repositories),
      forceMaterialScrim: repositories.isShowingCanvas && isCanvasCardExpanded
    )
    let actions = makeFocusedActions(
      repositories: repositories,
      hasActiveWorktree: hasActiveTerminalTarget,
      runScriptEnabled: runScriptEnabled,
      runScriptIsRunning: runScriptIsRunning
    )
    let actionToken = WorktreeActionContext(
      selectedWorktreeID: selectedTerminalWorktree?.id,
      isShowingCanvas: repositories.isShowingCanvas,
      canvasFocusedWorktreeID: repositories.isShowingCanvas
        ? terminalManager.canvasFocusedWorktreeID : nil
    )
    return applyFocusedActions(content: content, actions: actions, token: actionToken)
  }

  @ToolbarContentBuilder
  private func worktreeToolbarContent(
    toolbarState: WorktreeToolbarState,
    actionTargetWorktree: Worktree?
  ) -> some ToolbarContent {
    WorktreeToolbarContent(
      toolbarState: toolbarState,
      onOpenWorktree: { action in
        store.send(.openWorktree(action))
      },
      onOpenActionSelectionChanged: { action in
        store.send(.openActionSelectionChanged(action))
      },
      onResetOpenActionToAutomatic: {
        store.send(.openActionResetToAutomatic)
      },
      onCopyPath: {
        guard let actionTargetWorktree else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(actionTargetWorktree.workingDirectory.path, forType: .string)
      },
      onSelectNotification: selectToolbarNotification,
      onDismissAllNotifications: {
        dismissAllToolbarNotifications(in: toolbarState.shared.notificationGroups)
      },
      onRunScript: { store.send(.runScript) },
      onStopRunScript: { store.send(.stopRunScript) },
      onRunCustomCommand: { index in
        store.send(.runCustomCommand(index))
      },
      onActivateUpdateButton: { store.send(.updates(.activateUpdateButton)) },
      onHandOff: { store.send(.openHandoffHud) },
      onLaunchProfile: { store.send(.launchAgentProfile($0)) },
      onManageProfiles: { store.send(.openAgentProfilesSettings) },
      onRunWorkflow: { key in
        store.send(
          .openWorkflowStart(
            workflowKey: key, worktreeID: nil, sourceSurfaceID: nil, forceSheet: false))
      },
      onRunWorkflowWithOptions: { key in
        store.send(
          .openWorkflowStart(
            workflowKey: key, worktreeID: nil, sourceSurfaceID: nil, forceSheet: true))
      },
      onShowWorkflowDetails: { item in
        guard let worktreeID = actionTargetWorktree?.id else { return }
        store.send(.openWorkflowDetails(item, worktreeID: worktreeID))
      },
      onWorkflowIntent: handleWorkflowIntent
    )
  }

  private func loadWorkflowHistory(context: WorkflowHistoryContext, runs: [WorkflowRun]) {
    historyStore.send(.context(context))
    historyStore.send(.liveRuns(runs))
    historyStore.send(.refresh)
  }

  private func workflowHistoryContext(worktree: Worktree?, repositories: RepositoriesFeature.State)
    -> WorkflowHistoryContext
  {
    let pane = worktree.flatMap { terminalManager.stateIfExists(for: $0.id)?.currentFocusedSurfaceId() }
    let agent = repositories.activeAgents.entries.first { $0.surfaceID == pane }
    return WorkflowHistoryContext(
      paneID: pane,
      session: agent.flatMap { entry in
        WorkflowHistorySessionIdentity.resolve(
          agent: entry.agent, detected: entry.session,
          currentSignal: terminalManager.currentAgentSignalEvidenceSnapshot(surfaceID: entry.surfaceID)
            .latestManagedHook)
      },
      worktreeID: worktree?.id,
      livePaneIDs: Set(terminalManager.activeWorktreeStates.flatMap { $0.surfaces.keys }))
  }

  private func toolbarSharedState(
    input: ToolbarSharedStateInput
  ) -> ToolbarSharedState {
    ToolbarSharedState(
      actionTargetWorktreeID: input.actionTargetWorktree?.id,
      agentsCapsule: agentsCapsuleState(for: input.actionTargetWorktree),
      agentsLauncherItems: agentsLauncherItems(for: input.actionTargetWorktree),
      statusToast: input.repositories.statusToast,
      workflowStatus: WorkflowStatusCenterPresentation(
        state: input.workflowRuns,
        selectedWorktreeID: input.actionTargetWorktree?.id,
        now: Date()
      ),
      pullRequest: matchedPullRequest(
        for: input.actionTargetWorktree,
        repositories: input.repositories
      ),
      codeHost: input.repositories.codeHost(forWorktreeID: input.actionTargetWorktree?.id),
      notificationGroups: input.notificationGroups,
      unseenNotificationWorktreeCount: input.unseenNotificationWorktreeCount,
      runScriptEnabled: input.runScriptEnabled,
      runScriptIsRunning: input.runScriptIsRunning,
      customCommands: input.customCommands,
      isUpdateAvailable: input.isUpdateAvailable,
      isUpdateReadyToInstall: input.isUpdateReadyToInstall,
      availableUpdateVersion: input.availableUpdateVersion,
      showRunButtonInToolbar: input.showRunButtonInToolbar
    )
  }

  @ToolbarContentBuilder
  private func canvasToolbarContent(
    state: ToolbarSharedState
  ) -> some ToolbarContent {
    AgentNotificationsToolbarContent(
      onHistoryIntent: handleWorkflowIntent,
      agentsCapsule: state.agentsCapsule,
      agentsLauncherItems: state.agentsLauncherItems,
      notificationGroups: state.notificationGroups,
      unseenNotificationWorktreeCount: state.unseenNotificationWorktreeCount,
      workflowsWorktreeID: state.actionTargetWorktreeID,
      onHandOff: { store.send(.openHandoffHud) },
      onLaunchProfile: { store.send(.launchAgentProfile($0)) },
      onManageProfiles: { store.send(.openAgentProfilesSettings) },
      onRunWorkflow: { key in
        store.send(
          .openWorkflowStart(
            workflowKey: key, worktreeID: nil, sourceSurfaceID: nil, forceSheet: false))
      },
      onRunWorkflowWithOptions: { key in
        store.send(
          .openWorkflowStart(
            workflowKey: key, worktreeID: nil, sourceSurfaceID: nil, forceSheet: true))
      },
      onShowWorkflowDetails: { item in
        guard let worktreeID = state.actionTargetWorktreeID else { return }
        store.send(.openWorkflowDetails(item, worktreeID: worktreeID))
      },
      onSelectNotification: selectToolbarNotification,
      onDismissAllNotifications: {
        dismissAllToolbarNotifications(in: state.notificationGroups)
      },
      isUpdateAvailable: state.isUpdateAvailable,
      isUpdateReadyToInstall: state.isUpdateReadyToInstall,
      availableUpdateVersion: state.availableUpdateVersion,
      onActivateUpdateButton: { store.send(.updates(.activateUpdateButton)) }
    )

    ToolbarItem(placement: .principal) {
      ToolbarStatusView(
        toast: state.statusToast,
        workflow: state.workflowStatus,
        pullRequest: state.pullRequest,
        codeHost: state.codeHost,
        onWorkflowIntent: handleWorkflowIntent
      )
      .padding(.horizontal)
    }

    let showRunButton =
      state.showRunButtonInToolbar
      && (state.runScriptIsRunning || state.runScriptEnabled)
    let overflowCommands = Array(state.customCommands.enumerated().dropFirst(3))
    // A fixed separator keeps the dynamic Run + Custom Command cluster distinct
    // from other trailing actions, mirroring the Normal toolbar spacing.
    //
    // INTENTIONAL DIVERGENCE FROM THE NORMAL TOOLBAR: the whole cluster is a
    // single `ToolbarItem` (an HStack) here, whereas `commandToolbarItems`
    // (Normal mode) lays the buttons out as separate items / a
    // `ToolbarItemGroup`. The reason is how each mode updates NSToolbar (which
    // SwiftUI's `.toolbar` bridges to):
    //   - Normal: switching worktree swaps the whole detail view, so NSToolbar
    //     is rebuilt wholesale — no per-item diff, no animation.
    //   - Canvas: `CanvasView` stays mounted across card switches; only the
    //     toolbar items change. With a multi-item structure NSToolbar performs
    //     an incremental insert/remove with its own animation (which SwiftUI
    //     transactions can't suppress), briefly overflowing the toolbar — the
    //     visible "jump" when switching between cards with different command
    //     counts.
    // Collapsing the cluster into one item keeps NSToolbar's item set stable,
    // so a command-count change is just an internal HStack relayout. Do NOT
    // "unify" this back into a `ToolbarItemGroup` to match Normal — that
    // reintroduces the jump.
    if showRunButton || !state.customCommands.isEmpty {
      ToolbarSpacer(.fixed)
      ToolbarItem(placement: .primaryAction) {
        // `spacing: 0` keeps the cluster as tight as the Normal toolbar's
        // ToolbarItemGroup (whose buttons sit nearly flush on macOS 26); the
        // buttons' own internal padding provides the visible gap.
        HStack(spacing: 0) {
          if showRunButton {
            RunScriptToolbarButton(
              isRunning: state.runScriptIsRunning,
              isEnabled: state.runScriptEnabled,
              runHelpText: AppShortcuts.helpText(
                title: "Run Script",
                commandID: AppShortcuts.CommandID.runScript,
                in: store.resolvedKeybindings
              ),
              stopHelpText: AppShortcuts.helpText(
                title: "Stop Script",
                commandID: AppShortcuts.CommandID.stopScript,
                in: store.resolvedKeybindings
              ),
              runShortcut: store.resolvedKeybindings.display(for: AppShortcuts.CommandID.runScript),
              stopShortcut: store.resolvedKeybindings.display(
                for: AppShortcuts.CommandID.stopScript),
              runAction: { store.send(.runScript) },
              stopAction: { store.send(.stopRunScript) }
            )
          }
          ForEach(Array(state.customCommands.enumerated().prefix(3)), id: \.element.id) { _, command in
            UserCustomCommandToolbarButton(
              title: command.command.resolvedTitle,
              systemImage: command.command.resolvedSystemImage,
              source: command.source,
              shortcut: store.resolvedKeybindings.display(
                for: command.keybindingID
              ),
              isEnabled: command.command.hasRunnableCommand,
              action: {
                store.send(.runCustomCommand(command.id))
              }
            )
          }
          if !overflowCommands.isEmpty {
            CustomCommandOverflowButton(
              entries: overflowCommands.map { $0.element },
              shortcutDisplay: { command in
                store.resolvedKeybindings.display(for: command.keybindingID)
              },
              onRunCustomCommand: { id in
                store.send(.runCustomCommand(id))
              }
            )
          }
        }
      }
    }
  }

  /// The target pane's detected agent, feeding the Agents capsule. nil
  /// (no detected agent) renders the capsule in its generic form; launcher
  /// availability is resolved separately from the target worktree (docs-ai 053).
  private func agentsCapsuleState(for worktree: Worktree?) -> AgentsCapsuleState? {
    guard let worktree,
      let state = terminalManager.stateIfExists(for: worktree.id),
      let tabID = state.tabManager.selectedTabId,
      let surfaceID = state.activeSurfaceID(for: tabID),
      let paneState = state.surfaceAgentStates[surfaceID],
      let agent = paneState.detectedAgent
    else { return nil }
    let iconSource =
      paneState.iconLookupToken.flatMap(CommandIconMap.iconForFirstToken)
      ?? CommandIconMap.iconForFirstToken(agent.iconLookupToken)
    // Same naming rule as the Active Agents rows: the launch profile name
    // recorded at surface creation wins for Prowl-launched panes; launch
    // aliases such as `omp` show their own name, not the semantic agent's.
    // Runtime-gated like `configRoot`: a *different* agent started manually
    // in the same pane must not wear the old profile's name (docs-ai 053/005).
    let launchProfile = state.launchProfilesBySurface[surfaceID]
    let displayName =
      (launchProfile?.runtime.agent == agent ? launchProfile?.name : nil)
      ?? ActiveAgentEntry.displayName(
        iconLookupToken: paneState.iconLookupToken ?? agent.iconLookupToken,
        agent: agent
      )
    return AgentsCapsuleState(
      displayName: displayName,
      iconSource: iconSource,
      infoLine: "Pass this task to another agent in a new tab. "
        + "\(displayName) writes its own briefing first."
    )
  }

  /// Launchable profile rows for the Agents popover: the current worktree's
  /// Recommended profile first, then the remaining enabled profiles in list
  /// order. Availability (CLI installed) is presentation-only — a missing
  /// runtime grays the row with a reason instead of silently recommending
  /// another profile (docs-ai 053).
  private func agentsLauncherItems(for worktree: Worktree?) -> [AgentsLauncherItem] {
    @Shared(.userGlobalSettings) var globalSettings
    let profiles = globalSettings.agentProfiles
    guard let worktree, !profiles.isEmpty else { return [] }
    @Shared(.userRepositorySettings(worktree.repositoryRootURL)) var repositorySettings
    let recommendedID =
      AgentProfileRecommendation.recommendedProfile(
        profiles: profiles,
        designatedID: repositorySettings.defaultAgentProfileID,
        lastLaunchedID: repositorySettings.lastLaunchedAgentProfileID
      )?.id
    let enabled = profiles.filter(\.isEnabled)
    let ordered = enabled.sorted { lhs, rhs in
      (lhs.id == recommendedID ? 0 : 1) < (rhs.id == recommendedID ? 0 : 1)
    }
    return ordered.map { profile in
      AgentsLauncherItem(
        id: profile.id,
        name: profile.name,
        runtimeName: AgentRuntimeAdapterRegistry.displayName(for: profile.runtime),
        iconSource: profile.iconSource,
        isRecommended: profile.id == recommendedID,
        availabilityWarning: AgentProfileAvailability.launchWarning(for: profile)
      )
    }
  }

  private func selectedWorktreeSummaries(
    from repositories: RepositoriesFeature.State
  ) -> [MultiSelectedWorktreeSummary] {
    repositories.sidebarSelectedWorktreeIDs
      .compactMap { worktreeID in
        repositories.selectedRow(for: worktreeID).map {
          MultiSelectedWorktreeSummary(
            id: $0.id,
            name: $0.name,
            repositoryName: repositories.repositoryName(for: $0.repositoryID)
          )
        }
      }
      .sorted { lhs, rhs in
        let lhsRepository = lhs.repositoryName ?? ""
        let rhsRepository = rhs.repositoryName ?? ""
        if lhsRepository == rhsRepository {
          return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhsRepository.localizedCaseInsensitiveCompare(rhsRepository) == .orderedAscending
      }
  }

  private func matchedPullRequest(
    for worktree: Worktree?,
    repositories: RepositoriesFeature.State
  ) -> GithubPullRequest? {
    guard let worktree,
      let pullRequest = repositories.worktreeInfo(for: worktree.id)?.pullRequest
    else {
      return nil
    }
    guard pullRequest.headRefName == nil || pullRequest.headRefName == worktree.name else {
      return nil
    }
    return pullRequest
  }

  private func shouldShowMultiSelectionSummary(
    repositories: RepositoriesFeature.State,
    selectedWorktreeSummaries: [MultiSelectedWorktreeSummary]
  ) -> Bool {
    !repositories.isShowingArchivedWorktrees
      && !repositories.isShowingCanvas
      && selectedWorktreeSummaries.count > 1
  }

  private func canvasFocusedTerminalWorktree(repositories: RepositoriesFeature.State) -> Worktree? {
    guard repositories.isShowingCanvas,
      let worktreeID = terminalManager.canvasFocusedWorktreeID
    else {
      return nil
    }
    if let worktree = repositories.worktree(for: worktreeID) {
      return worktree
    }
    guard let repository = repositories.repositories[id: worktreeID],
      repository.capabilities.supportsRunnableFolderActions,
      !repository.capabilities.supportsWorktrees
    else {
      return nil
    }
    return Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )
  }

  @ViewBuilder
  private func detailContent(
    repositories: RepositoriesFeature.State,
    loadingInfo: WorktreeLoadingInfo?,
    selectedWorktree: Worktree?,
    selectedTerminalWorktree: Worktree?,
    selectedWorktreeSummaries: [MultiSelectedWorktreeSummary]
  ) -> some View {
    if repositories.isShowingCanvas {
      CanvasView(
        terminalManager: terminalManager,
        repositoryCustomTitles: repositories.repositoryCustomTitles,
        focusRequest: repositories.pendingCanvasFocusRequest,
        commandRequest: repositories.pendingCanvasCommandRequest,
        onFocusedWorktreeChanged: { worktreeID in
          store.send(.canvasFocusedWorktreeChanged(worktreeID))
        },
        onFocusRequestConsumed: { requestID in
          store.send(.repositories(.consumeCanvasFocusRequest(requestID)))
        },
        onCommandConsumed: { requestID in
          store.send(.repositories(.consumeCanvasCommandRequest(requestID)))
        },
        onExpandedChange: { expanded in
          isCanvasCardExpanded = expanded
        }
      )
      // Canvas tints the nav (leading) only; the toolbar is left untinted so
      // floating cards don't read against a colored band. The card title
      // bars still carry their own per-repo color.
      .windowChromeTint(chromeFill(repositories: repositories, context: .canvas), edges: [.leading])
    } else if repositories.isShowingShelf {
      // Shelf manages its own chrome bands (and its always-repo-colored
      // spine) inside `ShelfView`, so no tint modifier is applied here.
      ShelfView(
        store: store.scope(state: \.repositories, action: \.repositories),
        terminalManager: terminalManager,
        createTab: { store.send(.newTerminal) }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      // Normal view mode (terminal, archived list, multi-selection, loading,
      // repository detail, empty): tint the toolbar (top) and nav (leading)
      // chrome, and pass the same fill into the terminal tab bar so its
      // background reads as part of the same tinted chrome.
      let normalFill = chromeFill(repositories: repositories, context: .normal)
      normalModeContent(
        repositories: repositories,
        loadingInfo: loadingInfo,
        selectedTerminalWorktree: selectedTerminalWorktree,
        selectedWorktreeSummaries: selectedWorktreeSummaries,
        barTint: normalFill
      )
      .windowChromeTint(normalFill, edges: [.top, .leading])
    }
  }

  @ViewBuilder
  private func normalModeContent(
    repositories: RepositoriesFeature.State,
    loadingInfo: WorktreeLoadingInfo?,
    selectedTerminalWorktree: Worktree?,
    selectedWorktreeSummaries: [MultiSelectedWorktreeSummary],
    barTint: WindowChromeTint.Fill?
  ) -> some View {
    if repositories.isShowingArchivedWorktrees {
      ArchivedWorktreesDetailView(
        store: store.scope(state: \.repositories, action: \.repositories)
      )
    } else if shouldShowMultiSelectionSummary(
      repositories: repositories,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    ) {
      MultiSelectedWorktreesDetailView(rows: selectedWorktreeSummaries)
    } else if let loadingInfo {
      WorktreeLoadingView(info: loadingInfo)
    } else if let selectedTerminalWorktree {
      let shouldRunSetupScript = repositories.pendingSetupScriptWorktreeIDs.contains(
        selectedTerminalWorktree.id)
      let shouldFocusTerminal = repositories.shouldFocusTerminal(for: selectedTerminalWorktree.id)
      WorktreeTerminalTabsView(
        worktree: selectedTerminalWorktree,
        manager: terminalManager,
        shouldRunSetupScript: shouldRunSetupScript,
        forceAutoFocus: shouldFocusTerminal,
        createTab: { store.send(.newTerminal) },
        barTint: barTint
      )
      .id(selectedTerminalWorktree.id)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        if shouldFocusTerminal {
          store.send(
            .repositories(.worktreeCreation(.consumeTerminalFocus(selectedTerminalWorktree.id))))
        }
      }
    } else if let selectedRepository = repositories.selectedRepository {
      RepositoryDetailView(
        repository: selectedRepository,
        customTitle: repositories.repositoryCustomTitles[selectedRepository.id]
      )
    } else {
      EmptyStateView(store: store.scope(state: \.repositories, action: \.repositories))
    }
  }

  /// The chrome region a tint is being resolved for.
  private enum ChromeContext {
    case normal
    case canvas
  }

  /// Resolves the chrome band fill for the current view mode, honoring the
  /// user's window tint setting. In `.repositoryColor` mode the band tracks
  /// the active repository — the selected worktree's repo in Normal, the
  /// focused card's repo in Canvas — falling back to a neutral surface when
  /// none is colored.
  private func chromeFill(
    repositories: RepositoriesFeature.State,
    context: ChromeContext
  ) -> WindowChromeTint.Fill? {
    let repositoryID: Repository.ID? =
      switch context {
      case .normal:
        repositories.repositoryID(for: repositories.selectedWorktreeID)
          ?? repositories.selectedRepositoryID
      case .canvas:
        repositories.repositoryID(for: terminalManager.canvasFocusedWorktreeID)
      }
    let repositoryColor = repositoryID.flatMap { repositoryAppearances[$0]?.color }
    return WindowChromeTint.fill(
      mode: settingsFile.global.windowTintMode,
      customColor: settingsFile.global.windowTintCustomColor.color,
      repositoryColor: repositoryColor
    )
  }

  /// Resolves the real window toolbar background. Unlike the content tint
  /// bands, this applies to the AppKit/SwiftUI toolbar surface itself, which
  /// remains visible when macOS changes the zoomed/fullscreen window layout.
  private func toolbarChromeFill(repositories: RepositoriesFeature.State) -> WindowChromeTint.Fill? {
    guard !repositories.isShowingCanvas else { return nil }
    return chromeFill(repositories: repositories, context: .normal)
  }

  private func applyFocusedActions<Content: View>(
    content: Content,
    actions: FocusedActions,
    token: WorktreeActionContext
  ) -> some View {
    content
      .focusedSceneValue(
        \.openSelectedWorktreeAction, actions.openSelectedWorktree.asFocusedAction(token: token)
      )
      .focusedSceneValue(\.newTerminalAction, actions.newTerminal.asFocusedAction(token: token))
      .focusedSceneValue(\.closeTabAction, actions.closeTab.asFocusedAction(token: token))
      .focusedSceneValue(\.closeSurfaceAction, actions.closeSurface.asFocusedAction(token: token))
      .focusedSceneValue(\.resetFontSizeAction, actions.resetFontSize.asFocusedAction(token: token))
      .focusedSceneValue(
        \.increaseFontSizeAction, actions.increaseFontSize.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.decreaseFontSizeAction, actions.decreaseFontSize.asFocusedAction(token: token)
      )
      .focusedSceneValue(\.startSearchAction, actions.startSearch.asFocusedAction(token: token))
      .focusedSceneValue(
        \.searchSelectionAction, actions.searchSelection.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.navigateSearchNextAction, actions.navigateSearchNext.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.navigateSearchPreviousAction, actions.navigateSearchPrevious.asFocusedAction(token: token)
      )
      .focusedSceneValue(\.endSearchAction, actions.endSearch.asFocusedAction(token: token))
      .focusedSceneValue(
        \.selectPreviousTerminalTabAction,
        actions.selectPreviousTerminalTab.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectNextTerminalTabAction, actions.selectNextTerminalTab.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectPreviousTerminalPaneAction,
        actions.selectPreviousTerminalPane.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectNextTerminalPaneAction, actions.selectNextTerminalPane.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectTerminalPaneAboveAction,
        actions.selectTerminalPaneAbove.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectTerminalPaneBelowAction,
        actions.selectTerminalPaneBelow.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectTerminalPaneLeftAction, actions.selectTerminalPaneLeft.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectTerminalPaneRightAction,
        actions.selectTerminalPaneRight.asFocusedAction(token: token)
      )
      .focusedSceneValue(\.runScriptAction, actions.runScript.asFocusedAction(token: token))
      .focusedSceneValue(\.stopRunScriptAction, actions.stopRunScript.asFocusedAction(token: token))
  }

  private func makeFocusedActions(
    repositories: RepositoriesFeature.State,
    hasActiveWorktree: Bool,
    runScriptEnabled: Bool,
    runScriptIsRunning: Bool
  ) -> FocusedActions {
    func action(_ appAction: AppFeature.Action) -> (() -> Void)? {
      hasActiveWorktree ? { store.send(appAction) } : nil
    }

    func canvasAction(_ perform: @escaping (WorktreeTerminalState) -> Bool) -> (() -> Void)? {
      guard repositories.isShowingCanvas else { return nil }
      return {
        guard let worktreeID = terminalManager.canvasFocusedWorktreeID,
          let state = terminalManager.stateIfExists(for: worktreeID)
        else {
          return
        }
        _ = perform(state)
      }
    }

    func fontSizeAction(_ bindingAction: String) -> (() -> Void)? {
      if repositories.isShowingCanvas {
        return {
          guard let worktreeID = terminalManager.canvasFocusedWorktreeID,
            let state = terminalManager.stateIfExists(for: worktreeID)
          else { return }
          _ = state.performBindingActionOnFocusedSurface(bindingAction)
          terminalManager.syncPreferredFontSize(from: worktreeID)
        }
      }
      guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree else {
        return nil
      }
      return {
        guard let state = terminalManager.stateIfExists(for: selectedWorktree.id) else { return }
        _ = state.performBindingActionOnFocusedSurface(bindingAction)
        terminalManager.syncPreferredFontSize(from: selectedWorktree.id)
      }
    }

    func terminalBindingAction(_ bindingAction: String) -> (() -> Void)? {
      if let action = canvasAction({ $0.performBindingActionOnFocusedSurface(bindingAction) }) {
        return action
      }
      guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree else {
        return nil
      }
      return {
        guard let state = terminalManager.stateIfExists(for: selectedWorktree.id) else { return }
        _ = state.performBindingActionOnFocusedSurface(bindingAction)
      }
    }

    return FocusedActions(
      openSelectedWorktree: action(.openSelectedWorktree),
      newTerminal: action(.newTerminal),
      closeTab: closeTabFocusedAction(
        repositories: repositories, hasActiveWorktree: hasActiveWorktree),
      closeSurface: closeSurfaceFocusedAction(
        repositories: repositories, hasActiveWorktree: hasActiveWorktree),
      resetFontSize: fontSizeAction("reset_font_size"),
      increaseFontSize: fontSizeAction("increase_font_size:1"),
      decreaseFontSize: fontSizeAction("decrease_font_size:1"),
      startSearch: action(.startSearch),
      searchSelection: action(.searchSelection),
      navigateSearchNext: action(.navigateSearchNext),
      navigateSearchPrevious: action(.navigateSearchPrevious),
      endSearch: action(.endSearch),
      selectPreviousTerminalTab: terminalBindingAction("previous_tab"),
      selectNextTerminalTab: terminalBindingAction("next_tab"),
      selectPreviousTerminalPane: terminalBindingAction("goto_split:previous"),
      selectNextTerminalPane: terminalBindingAction("goto_split:next"),
      selectTerminalPaneAbove: terminalBindingAction("goto_split:up"),
      selectTerminalPaneBelow: terminalBindingAction("goto_split:down"),
      selectTerminalPaneLeft: terminalBindingAction("goto_split:left"),
      selectTerminalPaneRight: terminalBindingAction("goto_split:right"),
      runScript: runScriptEnabled ? { store.send(.runScript) } : nil,
      stopRunScript: runScriptIsRunning ? { store.send(.stopRunScript) } : nil
    )
  }

  private func closeTabFocusedAction(
    repositories: RepositoriesFeature.State,
    hasActiveWorktree: Bool
  ) -> (() -> Void)? {
    if repositories.isShowingCanvas {
      guard let worktreeID = terminalManager.canvasFocusedWorktreeID,
        let state = terminalManager.stateIfExists(for: worktreeID),
        state.canCloseFocusedTab
      else { return nil }
      return { _ = state.closeFocusedTab() }
    }
    guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree,
      terminalManager.stateIfExists(for: selectedWorktree.id)?.canCloseFocusedTab == true
    else { return nil }
    return { store.send(.closeTab) }
  }

  private func closeSurfaceFocusedAction(
    repositories: RepositoriesFeature.State,
    hasActiveWorktree: Bool
  ) -> (() -> Void)? {
    if repositories.isShowingCanvas {
      guard let worktreeID = terminalManager.canvasFocusedWorktreeID,
        let state = terminalManager.stateIfExists(for: worktreeID),
        state.canCloseFocusedSurface
      else { return nil }
      return { _ = state.closeFocusedSurface() }
    }
    guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree,
      terminalManager.stateIfExists(for: selectedWorktree.id)?.canCloseFocusedSurface == true
    else { return nil }
    return { store.send(.closeSurface) }
  }

  private func selectToolbarNotification(
    _ worktreeID: Worktree.ID,
    _ notification: WorktreeTerminalNotification
  ) {
    if let runID = notification.workflowRunID {
      terminalManager.markNotificationRead(worktreeID: worktreeID, notificationID: notification.id)
      historyStore.send(.setPresented(true))
      historyStore.send(.select(runID))
      historyStore.send(.openRequested)
      return
    }
    store.send(.repositories(.selectWorktree(worktreeID)))
    if let terminalState = terminalManager.stateIfExists(for: worktreeID) {
      _ = terminalState.focusSurface(id: notification.surfaceId)
    }
  }

  private func dismissAllToolbarNotifications(in groups: [ToolbarNotificationRepositoryGroup]) {
    for repositoryGroup in groups {
      for worktreeGroup in repositoryGroup.worktrees {
        terminalManager.stateIfExists(for: worktreeGroup.id)?.dismissAllNotifications()
      }
    }
  }

  private func handleWorkflowIntent(_ intent: WorkflowRunPanelIntent) {
    switch intent {
    case .focusPane(let worktreeID, let surfaceID):
      store.send(.repositories(.selectWorktree(worktreeID)))
      _ = terminalManager.stateIfExists(for: worktreeID)?.focusSurface(id: surfaceID)
    case .userAction(let runID, let action):
      store.send(.workflowRuns(.userAction(runID: runID, action)))
    case .revealRunFolder(let url):
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    case .openLog(let url):
      NSWorkspace.shared.open(url)
    }
  }

  /// Hashable identity of the inputs the focused actions capture, used as the
  /// `FocusedAction` token. The detail body re-runs on every OSC-9 progress
  /// tick during agent activity; without a stable token each run would look
  /// like a focused-value change and rebuild the menu bar. Including the
  /// selected / canvas-focused worktree here keeps the published actions stable
  /// while the same worktree is focused, yet still republishes when the target
  /// worktree changes (so a menu item never fires against a stale worktree).
  private struct WorktreeActionContext: Hashable {
    let selectedWorktreeID: Worktree.ID?
    let isShowingCanvas: Bool
    let canvasFocusedWorktreeID: Worktree.ID?
  }

  private struct FocusedActions {
    let openSelectedWorktree: (() -> Void)?
    let newTerminal: (() -> Void)?
    let closeTab: (() -> Void)?
    let closeSurface: (() -> Void)?
    let resetFontSize: (() -> Void)?
    let increaseFontSize: (() -> Void)?
    let decreaseFontSize: (() -> Void)?
    let startSearch: (() -> Void)?
    let searchSelection: (() -> Void)?
    let navigateSearchNext: (() -> Void)?
    let navigateSearchPrevious: (() -> Void)?
    let endSearch: (() -> Void)?
    let selectPreviousTerminalTab: (() -> Void)?
    let selectNextTerminalTab: (() -> Void)?
    let selectPreviousTerminalPane: (() -> Void)?
    let selectNextTerminalPane: (() -> Void)?
    let selectTerminalPaneAbove: (() -> Void)?
    let selectTerminalPaneBelow: (() -> Void)?
    let selectTerminalPaneLeft: (() -> Void)?
    let selectTerminalPaneRight: (() -> Void)?
    let runScript: (() -> Void)?
    let stopRunScript: (() -> Void)?
  }

  struct ToolbarSharedState {
    let actionTargetWorktreeID: Worktree.ID?
    let agentsCapsule: AgentsCapsuleState?
    let agentsLauncherItems: [AgentsLauncherItem]
    let statusToast: RepositoriesFeature.StatusToast?
    let workflowStatus: WorkflowStatusCenterPresentation
    let pullRequest: GithubPullRequest?
    let codeHost: CodeHost
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let runScriptEnabled: Bool
    let runScriptIsRunning: Bool
    let customCommands: [EffectiveCustomCommand]
    let isUpdateAvailable: Bool
    let isUpdateReadyToInstall: Bool
    let availableUpdateVersion: String?
    let showRunButtonInToolbar: Bool
  }

  struct WorktreeToolbarState {
    let shared: ToolbarSharedState
    let openActionSelection: OpenWorktreeAction
    let openActionIsAutomatic: Bool
    let showExtras: Bool
    let showDefaultEditorInToolbar: Bool
  }

  /// Shared leading toolbar cluster for Normal, Shelf, and Canvas. Agents and
  /// Quick Launch share one native group; notifications and update status share
  /// the trailing group that replaces the former branch item.
  struct AgentNotificationsToolbarContent: ToolbarContent {
    @Environment(StoreOf<WorkflowStepHistoryFeature>.self) private var historyStore
    @Dependency(FeatureFlags.self) private var historyFlags
    let onHistoryIntent: (WorkflowRunPanelIntent) -> Void

    let agentsCapsule: AgentsCapsuleState?
    let agentsLauncherItems: [AgentsLauncherItem]
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let workflowsWorktreeID: Worktree.ID?
    let onHandOff: () -> Void
    let onLaunchProfile: (AgentProfile.ID) -> Void
    let onManageProfiles: () -> Void
    let onRunWorkflow: (String) -> Void
    let onRunWorkflowWithOptions: (String) -> Void
    let onShowWorkflowDetails: (WorkflowStartCatalogItem) -> Void
    let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
    let onDismissAllNotifications: () -> Void
    let isUpdateAvailable: Bool
    let isUpdateReadyToInstall: Bool
    let availableUpdateVersion: String?
    let onActivateUpdateButton: () -> Void

    var body: some ToolbarContent {
      ToolbarItemGroup(placement: .navigation) {
        AgentsToolbarButton(
          capsule: agentsCapsule,
          launcherItems: agentsLauncherItems,
          workflowsWorktreeID: workflowsWorktreeID,
          onHandOff: onHandOff,
          onLaunchProfile: onLaunchProfile,
          onManageProfiles: onManageProfiles,
          onRunWorkflow: onRunWorkflow,
          onRunWorkflowWithOptions: onRunWorkflowWithOptions,
          onShowWorkflowDetails: onShowWorkflowDetails
        )
        if let quickLaunchItem = agentsLauncherItems.first {
          AgentsQuickLaunchButton(item: quickLaunchItem, onLaunch: onLaunchProfile)
        }
      }

      // Adjacent navigation groups merge on macOS 26. This isolated item owns
      // the second capsule; see docs-ai 061 before changing its structure.
      ToolbarItem(placement: .navigation) {
        HStack(spacing: 0) {
          ToolbarNotificationsPopoverButton(
            groups: notificationGroups,
            unseenWorktreeCount: unseenNotificationWorktreeCount,
            onSelectNotification: onSelectNotification,
            onDismissAll: onDismissAllNotifications
          )
          if historyFlags.workflowUI && !historyStore.entries.isEmpty {
            WorkflowHistoryPopoverButton(store: historyStore, onIntent: onHistoryIntent)
          }
          if isUpdateAvailable {
            ToolbarUpdateButton(
              availableVersion: availableUpdateVersion,
              isReadyToInstall: isUpdateReadyToInstall,
              onActivate: onActivateUpdateButton
            )
          }
        }
        .glassEffect(.regular.interactive(), in: Capsule())
      }
      .sharedBackgroundVisibility(.hidden)
    }
  }

  struct WorktreeToolbarContent: ToolbarContent {
    let toolbarState: WorktreeToolbarState
    let onOpenWorktree: (OpenWorktreeAction) -> Void
    let onOpenActionSelectionChanged: (OpenWorktreeAction) -> Void
    let onResetOpenActionToAutomatic: () -> Void
    let onCopyPath: () -> Void
    let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
    let onDismissAllNotifications: () -> Void
    let onRunScript: () -> Void
    let onStopRunScript: () -> Void
    let onRunCustomCommand: (EffectiveCustomCommand.Identifier) -> Void
    let onActivateUpdateButton: () -> Void
    let onHandOff: () -> Void
    let onLaunchProfile: (AgentProfile.ID) -> Void
    let onManageProfiles: () -> Void
    let onRunWorkflow: (String) -> Void
    let onRunWorkflowWithOptions: (String) -> Void
    let onShowWorkflowDetails: (WorkflowStartCatalogItem) -> Void
    let onWorkflowIntent: (WorkflowRunPanelIntent) -> Void
    @Environment(\.resolvedKeybindings) private var resolvedKeybindings

    var body: some ToolbarContent {
      AgentNotificationsToolbarContent(
        onHistoryIntent: onWorkflowIntent,
        agentsCapsule: toolbarState.shared.agentsCapsule,
        agentsLauncherItems: toolbarState.shared.agentsLauncherItems,
        notificationGroups: toolbarState.shared.notificationGroups,
        unseenNotificationWorktreeCount: toolbarState.shared.unseenNotificationWorktreeCount,
        workflowsWorktreeID: toolbarState.shared.actionTargetWorktreeID,
        onHandOff: onHandOff,
        onLaunchProfile: onLaunchProfile,
        onManageProfiles: onManageProfiles,
        onRunWorkflow: onRunWorkflow,
        onRunWorkflowWithOptions: onRunWorkflowWithOptions,
        onShowWorkflowDetails: onShowWorkflowDetails,
        onSelectNotification: onSelectNotification,
        onDismissAllNotifications: onDismissAllNotifications,
        isUpdateAvailable: toolbarState.shared.isUpdateAvailable,
        isUpdateReadyToInstall: toolbarState.shared.isUpdateReadyToInstall,
        availableUpdateVersion: toolbarState.shared.availableUpdateVersion,
        onActivateUpdateButton: onActivateUpdateButton
      )

      ToolbarItem(placement: .principal) {
        ToolbarStatusView(
          toast: toolbarState.shared.statusToast,
          workflow: toolbarState.shared.workflowStatus,
          pullRequest: toolbarState.shared.pullRequest,
          codeHost: toolbarState.shared.codeHost,
          onWorkflowIntent: onWorkflowIntent
        )
        .padding(.horizontal)
      }

      if toolbarState.showDefaultEditorInToolbar {
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
          openMenu(
            openActionSelection: toolbarState.openActionSelection,
            openActionIsAutomatic: toolbarState.openActionIsAutomatic,
            showExtras: toolbarState.showExtras
          )
        }
      }
      commandToolbarItems

    }

    @ViewBuilder
    private func openMenu(
      openActionSelection: OpenWorktreeAction,
      openActionIsAutomatic: Bool,
      showExtras: Bool
    ) -> some View {
      let availableActions = OpenWorktreeAction.availableCases
      let resolvedOpenActionSelection = OpenWorktreeAction.availableSelection(openActionSelection)
      Button {
        onOpenWorktree(resolvedOpenActionSelection)
      } label: {
        OpenWorktreeActionMenuLabelView(
          action: resolvedOpenActionSelection,
          shortcutHint: showExtras ? shortcutDisplay(for: AppShortcuts.CommandID.openWorktree) : nil
        )
      }
      .help(openActionHelpText(for: resolvedOpenActionSelection, isDefault: true))

      Menu {
        Button {
          onResetOpenActionToAutomatic()
        } label: {
          if openActionIsAutomatic {
            Label("Automatic", systemImage: "checkmark")
          } else {
            Text("Automatic")
          }
        }
        .buttonStyle(.plain)
        .help("Pick the app automatically based on the project type")
        Divider()
        ForEach(availableActions) { action in
          let isDefault = action == resolvedOpenActionSelection
          Button {
            onOpenActionSelectionChanged(action)
            onOpenWorktree(action)
          } label: {
            OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
          }
          .buttonStyle(.plain)
          .help(openActionHelpText(for: action, isDefault: isDefault))
        }
        Divider()
        Button("Copy Path") {
          onCopyPath()
        }
        .help("Copy path")
      } label: {
        Image(systemName: "chevron.down")
          .font(.caption2)
          .accessibilityLabel("Open in menu")
      }
      .imageScale(.small)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Open in...")

    }

    private func openActionHelpText(for action: OpenWorktreeAction, isDefault: Bool) -> String {
      guard isDefault else { return action.title }
      return AppShortcuts.helpText(
        title: action.title,
        commandID: AppShortcuts.CommandID.openWorktree,
        in: resolvedKeybindings
      )
    }

    @ToolbarContentBuilder
    private var commandToolbarItems: some ToolbarContent {
      let showRunButton =
        toolbarState.shared.showRunButtonInToolbar
        && (toolbarState.shared.runScriptIsRunning || toolbarState.shared.runScriptEnabled)
      let entries = customCommandEntries
      let inlineEntries = Array(entries.prefix(3))
      let overflowEntries = Array(entries.dropFirst(3))

      // One fixed separator in front of the whole Run + Custom Command cluster
      // keeps it distinct from preceding trailing actions no matter which items
      // are hidden. Run and the custom commands share one group (no spacer
      // between them), matching the grouping before the toolbar toggles.
      if showRunButton || !inlineEntries.isEmpty || !overflowEntries.isEmpty {
        ToolbarSpacer(.fixed)
      }

      if showRunButton {
        ToolbarItem {
          RunScriptToolbarButton(
            isRunning: toolbarState.shared.runScriptIsRunning,
            isEnabled: toolbarState.shared.runScriptEnabled,
            runHelpText: AppShortcuts.helpText(
              title: "Run Script",
              commandID: AppShortcuts.CommandID.runScript,
              in: resolvedKeybindings
            ),
            stopHelpText: AppShortcuts.helpText(
              title: "Stop Script",
              commandID: AppShortcuts.CommandID.stopScript,
              in: resolvedKeybindings
            ),
            runShortcut: shortcutDisplay(for: AppShortcuts.CommandID.runScript),
            stopShortcut: shortcutDisplay(for: AppShortcuts.CommandID.stopScript),
            runAction: onRunScript,
            stopAction: onStopRunScript
          )
        }
      }

      if !inlineEntries.isEmpty {
        ToolbarItemGroup {
          ForEach(inlineEntries) { entry in
            customCommandButton(entry)
          }
        }
      }

      if !overflowEntries.isEmpty {
        ToolbarItem {
          CustomCommandOverflowButton(
            entries: overflowEntries,
            shortcutDisplay: customCommandShortcutDisplay(for:),
            onRunCustomCommand: onRunCustomCommand
          )
        }
      }
    }

    private var customCommandEntries: [EffectiveCustomCommand] {
      toolbarState.shared.customCommands
    }

    private func customCommandButton(_ command: EffectiveCustomCommand) -> some View {
      UserCustomCommandToolbarButton(
        title: command.command.resolvedTitle,
        systemImage: command.command.resolvedSystemImage,
        source: command.source,
        shortcut: customCommandShortcutDisplay(for: command),
        isEnabled: command.command.hasRunnableCommand,
        action: {
          onRunCustomCommand(command.id)
        }
      )
    }

    private func customCommandShortcutDisplay(for command: EffectiveCustomCommand) -> String? {
      shortcutDisplay(for: command.keybindingID)
    }

    private func shortcutDisplay(for commandID: String) -> String? {
      AppShortcuts.display(for: commandID, in: resolvedKeybindings)
    }
  }

  private func loadingInfo(
    for selectedRow: WorktreeRowModel?,
    selectedWorktreeID: Worktree.ID?,
    repositories: RepositoriesFeature.State
  ) -> WorktreeLoadingInfo? {
    guard let selectedRow else { return nil }
    let repositoryName = repositories.repositoryName(for: selectedRow.repositoryID)
    let isFolder = repositories.repositories[id: selectedRow.repositoryID]?.kind == .plain
    if selectedRow.isDeleting {
      return WorktreeLoadingInfo(
        name: selectedRow.name,
        repositoryName: repositoryName,
        state: .removing,
        isFolder: isFolder,
        statusTitle: nil,
        statusDetail: nil,
        statusCommand: nil,
        statusLines: []
      )
    }
    if selectedRow.isArchiving {
      let progress = repositories.archiveScriptProgress(for: selectedWorktreeID)
      return WorktreeLoadingInfo(
        name: selectedRow.name,
        repositoryName: repositoryName,
        state: .archiving,
        statusTitle: progress?.titleText ?? selectedRow.name,
        statusDetail: progress?.detailText ?? selectedRow.detail,
        statusCommand: progress?.commandText,
        statusLines: progress?.outputLines ?? []
      )
    }
    if selectedRow.isPending {
      let pending = repositories.pendingWorktree(for: selectedWorktreeID)
      let progress = pending?.progress
      let displayName = progress?.worktreeName ?? selectedRow.name
      return WorktreeLoadingInfo(
        name: displayName,
        repositoryName: repositoryName,
        state: .creating,
        statusTitle: progress?.titleText ?? selectedRow.name,
        statusDetail: progress?.detailText ?? selectedRow.detail,
        statusCommand: progress?.commandText,
        statusLines: progress?.liveOutputLines ?? []
      )
    }
    return nil
  }
}
