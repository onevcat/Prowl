import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct WorktreeDetailView: View {
  private struct ToolbarStateInput {
    let repositories: RepositoriesFeature.State
    let selectedWorktree: Worktree?
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let openActionSelection: OpenWorktreeAction
    let openActionIsAutomatic: Bool
    let showExtras: Bool
    let runScriptEnabled: Bool
    let runScriptIsRunning: Bool
    let customCommands: [UserCustomCommand]
    let isUpdateAvailable: Bool
    let isUpdateReadyToInstall: Bool
    let availableUpdateVersion: String?
    let showRunButtonInToolbar: Bool
    let showDefaultEditorInToolbar: Bool
  }

  private struct CanvasToolbarState {
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let runScriptEnabled: Bool
    let runScriptIsRunning: Bool
    let customCommands: [UserCustomCommand]
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
    let runScriptIsRunning = actionTargetWorktree.flatMap { state.runScriptStatusByWorktreeID[$0.id] } == true
    let customCommands = state.selectedCustomCommands
    let notificationGroups = repositories.toolbarNotificationGroups(
      terminalManager: terminalManager,
      customTitles: repositories.repositoryCustomTitles
    )
    let unseenNotificationWorktreeCount = notificationGroups.reduce(0) { count, repository in
      count + repository.unseenWorktreeCount
    }
    let content = detailContent(
      repositories: repositories,
      loadingInfo: loadingInfo,
      selectedWorktree: selectedWorktree,
      selectedTerminalWorktree: selectedTerminalWorktree,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    )
    .navigationTitle(WindowTitle.compute(repositories: repositories, terminalManager: terminalManager))
    .toolbar(removing: repositories.isShowingCanvas ? nil : .title)
    .toolbar {
      if repositories.isShowingCanvas {
        canvasToolbarContent(
          state: CanvasToolbarState(
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
      } else if hasActiveTerminalTarget,
        let toolbarState = toolbarState(
          input: ToolbarStateInput(
            repositories: repositories,
            selectedWorktree: selectedWorktree,
            notificationGroups: notificationGroups,
            unseenNotificationWorktreeCount: unseenNotificationWorktreeCount,
            openActionSelection: state.openActionSelection,
            openActionIsAutomatic: state.openActionIsAutomatic,
            showExtras: commandKeyObserver.isPressed,
            runScriptEnabled: runScriptEnabled,
            runScriptIsRunning: runScriptIsRunning,
            customCommands: customCommands,
            isUpdateAvailable: state.updates.isUpdateAvailable,
            isUpdateReadyToInstall: state.updates.isUpdateReadyToInstall,
            availableUpdateVersion: state.updates.availableVersion,
            showRunButtonInToolbar: settingsFile.global.showRunButtonInToolbar,
            showDefaultEditorInToolbar: settingsFile.global.showDefaultEditorInToolbar
          )
        )
      {
        worktreeToolbarContent(
          toolbarState: toolbarState,
          repositories: repositories,
          selectedWorktree: selectedWorktree,
          actionTargetWorktree: actionTargetWorktree,
          notificationGroups: notificationGroups
        )
      }
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
      canvasFocusedWorktreeID: repositories.isShowingCanvas ? terminalManager.canvasFocusedWorktreeID : nil
    )
    return applyFocusedActions(content: content, actions: actions, token: actionToken)
  }

  @ToolbarContentBuilder
  private func worktreeToolbarContent(
    toolbarState: WorktreeToolbarState,
    repositories: RepositoriesFeature.State,
    selectedWorktree: Worktree?,
    actionTargetWorktree: Worktree?,
    notificationGroups: [ToolbarNotificationRepositoryGroup]
  ) -> some ToolbarContent {
    WorktreeToolbarContent(
      toolbarState: toolbarState,
      onRenameBranch: { newBranch in
        guard let selectedWorktree else { return }
        store.send(.repositories(.requestRenameBranch(selectedWorktree.id, newBranch)))
      },
      externalRenamePrompt: repositories.pendingRenameBranchRequest
        .flatMap { request in
          request.worktreeID == selectedWorktree?.id ? request : nil
        },
      onConsumeExternalRenamePrompt: { requestID in
        store.send(.repositories(.consumePendingRenameBranchRequest(requestID)))
      },
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
      onDismissAllNotifications: { dismissAllToolbarNotifications(in: notificationGroups) },
      onRunScript: { store.send(.runScript) },
      onStopRunScript: { store.send(.stopRunScript) },
      onRunCustomCommand: { index in
        store.send(.runCustomCommand(index))
      },
      onActivateUpdateButton: { store.send(.updates(.activateUpdateButton)) }
    )
  }

  @ToolbarContentBuilder
  private func canvasToolbarContent(
    state: CanvasToolbarState
  ) -> some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      ToolbarNotificationsPopoverButton(
        groups: state.notificationGroups,
        unseenWorktreeCount: state.unseenNotificationWorktreeCount,
        onSelectNotification: selectToolbarNotification,
        onDismissAll: { dismissAllToolbarNotifications(in: state.notificationGroups) }
      )
      if state.isUpdateAvailable {
        ToolbarUpdateButton(
          availableVersion: state.availableUpdateVersion,
          isReadyToInstall: state.isUpdateReadyToInstall
        ) {
          store.send(.updates(.activateUpdateButton))
        }
      }
    }

    let showRunButton =
      state.showRunButtonInToolbar
      && (state.runScriptIsRunning || state.runScriptEnabled)
    let inlineCommands = Array(state.customCommands.enumerated().prefix(3))
    let overflowCommands = Array(state.customCommands.enumerated().dropFirst(3))
    // A fixed separator splits the Run + Custom Command cluster from the
    // notification group, mirroring the Normal toolbar.
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
              stopShortcut: store.resolvedKeybindings.display(for: AppShortcuts.CommandID.stopScript),
              runAction: { store.send(.runScript) },
              stopAction: { store.send(.stopRunScript) }
            )
          }
          ForEach(inlineCommands, id: \.element.id) { index, command in
            UserCustomCommandToolbarButton(
              title: command.resolvedTitle,
              systemImage: command.resolvedSystemImage,
              shortcut: store.resolvedKeybindings.display(
                for: LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id)
              ),
              isEnabled: command.hasRunnableCommand,
              action: {
                store.send(.runCustomCommand(index))
              }
            )
          }
          if !overflowCommands.isEmpty {
            CustomCommandOverflowButton(
              entries: overflowCommands.map {
                (index: $0.offset, command: $0.element)
              },
              shortcutDisplay: { command in
                store.resolvedKeybindings.display(
                  for: LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id)
                )
              },
              onRunCustomCommand: { index in
                store.send(.runCustomCommand(index))
              }
            )
          }
        }
      }
    }
  }

  private func toolbarState(input: ToolbarStateInput) -> WorktreeToolbarState? {
    guard
      let title = DetailToolbarTitle.forSelection(
        worktree: input.selectedWorktree,
        repository: input.repositories.selectedRepository
      )
    else {
      return nil
    }
    let pullRequest = input.selectedWorktree.flatMap { input.repositories.worktreeInfo(for: $0.id)?.pullRequest }
    let matchesBranch =
      if let selectedWorktree = input.selectedWorktree, let pullRequest {
        pullRequest.headRefName == nil || pullRequest.headRefName == selectedWorktree.name
      } else {
        false
      }
    return WorktreeToolbarState(
      title: title,
      statusToast: input.repositories.statusToast,
      pullRequest: matchesBranch ? pullRequest : nil,
      codeHost: input.repositories.codeHost(forWorktreeID: input.selectedWorktree?.id),
      notificationGroups: input.notificationGroups,
      unseenNotificationWorktreeCount: input.unseenNotificationWorktreeCount,
      openActionSelection: input.openActionSelection,
      openActionIsAutomatic: input.openActionIsAutomatic,
      showExtras: input.showExtras,
      runScriptEnabled: input.runScriptEnabled,
      runScriptIsRunning: input.runScriptIsRunning,
      customCommands: input.customCommands,
      isUpdateAvailable: input.isUpdateAvailable,
      isUpdateReadyToInstall: input.isUpdateReadyToInstall,
      availableUpdateVersion: input.availableUpdateVersion,
      showRunButtonInToolbar: input.showRunButtonInToolbar,
      showDefaultEditorInToolbar: input.showDefaultEditorInToolbar
    )
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
      let shouldRunSetupScript = repositories.pendingSetupScriptWorktreeIDs.contains(selectedTerminalWorktree.id)
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
          store.send(.repositories(.worktreeCreation(.consumeTerminalFocus(selectedTerminalWorktree.id))))
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
        repositories.repositoryID(for: repositories.selectedWorktreeID) ?? repositories.selectedRepositoryID
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
      .focusedSceneValue(\.openSelectedWorktreeAction, actions.openSelectedWorktree.asFocusedAction(token: token))
      .focusedSceneValue(\.newTerminalAction, actions.newTerminal.asFocusedAction(token: token))
      .focusedSceneValue(\.closeTabAction, actions.closeTab.asFocusedAction(token: token))
      .focusedSceneValue(\.closeSurfaceAction, actions.closeSurface.asFocusedAction(token: token))
      .focusedSceneValue(\.resetFontSizeAction, actions.resetFontSize.asFocusedAction(token: token))
      .focusedSceneValue(\.increaseFontSizeAction, actions.increaseFontSize.asFocusedAction(token: token))
      .focusedSceneValue(\.decreaseFontSizeAction, actions.decreaseFontSize.asFocusedAction(token: token))
      .focusedSceneValue(\.startSearchAction, actions.startSearch.asFocusedAction(token: token))
      .focusedSceneValue(\.searchSelectionAction, actions.searchSelection.asFocusedAction(token: token))
      .focusedSceneValue(\.navigateSearchNextAction, actions.navigateSearchNext.asFocusedAction(token: token))
      .focusedSceneValue(
        \.navigateSearchPreviousAction, actions.navigateSearchPrevious.asFocusedAction(token: token)
      )
      .focusedSceneValue(\.endSearchAction, actions.endSearch.asFocusedAction(token: token))
      .focusedSceneValue(
        \.selectPreviousTerminalTabAction, actions.selectPreviousTerminalTab.asFocusedAction(token: token)
      )
      .focusedSceneValue(\.selectNextTerminalTabAction, actions.selectNextTerminalTab.asFocusedAction(token: token))
      .focusedSceneValue(
        \.selectPreviousTerminalPaneAction, actions.selectPreviousTerminalPane.asFocusedAction(token: token)
      )
      .focusedSceneValue(
        \.selectNextTerminalPaneAction, actions.selectNextTerminalPane.asFocusedAction(token: token)
      )
      .focusedSceneValue(\.selectTerminalPaneAboveAction, actions.selectTerminalPaneAbove.asFocusedAction(token: token))
      .focusedSceneValue(\.selectTerminalPaneBelowAction, actions.selectTerminalPaneBelow.asFocusedAction(token: token))
      .focusedSceneValue(\.selectTerminalPaneLeftAction, actions.selectTerminalPaneLeft.asFocusedAction(token: token))
      .focusedSceneValue(\.selectTerminalPaneRightAction, actions.selectTerminalPaneRight.asFocusedAction(token: token))
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
      guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree else { return nil }
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
      guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree else { return nil }
      return {
        guard let state = terminalManager.stateIfExists(for: selectedWorktree.id) else { return }
        _ = state.performBindingActionOnFocusedSurface(bindingAction)
      }
    }

    func closeTabAction() -> (() -> Void)? {
      if repositories.isShowingCanvas {
        guard let worktreeID = terminalManager.canvasFocusedWorktreeID,
          let state = terminalManager.stateIfExists(for: worktreeID),
          state.canCloseFocusedTab
        else {
          return nil
        }
        return { _ = state.closeFocusedTab() }
      }
      guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree,
        terminalManager.stateIfExists(for: selectedWorktree.id)?.canCloseFocusedTab == true
      else {
        return nil
      }
      return { store.send(.closeTab) }
    }

    func closeSurfaceAction() -> (() -> Void)? {
      if repositories.isShowingCanvas {
        guard let worktreeID = terminalManager.canvasFocusedWorktreeID,
          let state = terminalManager.stateIfExists(for: worktreeID),
          state.canCloseFocusedSurface
        else {
          return nil
        }
        return { _ = state.closeFocusedSurface() }
      }
      guard hasActiveWorktree, let selectedWorktree = repositories.selectedTerminalWorktree,
        terminalManager.stateIfExists(for: selectedWorktree.id)?.canCloseFocusedSurface == true
      else {
        return nil
      }
      return { store.send(.closeSurface) }
    }

    return FocusedActions(
      openSelectedWorktree: action(.openSelectedWorktree),
      newTerminal: action(.newTerminal),
      closeTab: closeTabAction(),
      closeSurface: closeSurfaceAction(),
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

  private func selectToolbarNotification(
    _ worktreeID: Worktree.ID,
    _ notification: WorktreeTerminalNotification
  ) {
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

  struct WorktreeToolbarState {
    let title: DetailToolbarTitle
    let statusToast: RepositoriesFeature.StatusToast?
    let pullRequest: GithubPullRequest?
    let codeHost: CodeHost
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let openActionSelection: OpenWorktreeAction
    let openActionIsAutomatic: Bool
    let showExtras: Bool
    let runScriptEnabled: Bool
    let runScriptIsRunning: Bool
    let customCommands: [UserCustomCommand]
    let isUpdateAvailable: Bool
    let isUpdateReadyToInstall: Bool
    let availableUpdateVersion: String?
    let showRunButtonInToolbar: Bool
    let showDefaultEditorInToolbar: Bool
  }

  struct WorktreeToolbarContent: ToolbarContent {
    let toolbarState: WorktreeToolbarState
    let onRenameBranch: (String) -> Void
    let externalRenamePrompt: PendingRenameBranchRequest?
    let onConsumeExternalRenamePrompt: (Int) -> Void
    let onOpenWorktree: (OpenWorktreeAction) -> Void
    let onOpenActionSelectionChanged: (OpenWorktreeAction) -> Void
    let onResetOpenActionToAutomatic: () -> Void
    let onCopyPath: () -> Void
    let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
    let onDismissAllNotifications: () -> Void
    let onRunScript: () -> Void
    let onStopRunScript: () -> Void
    let onRunCustomCommand: (Int) -> Void
    let onActivateUpdateButton: () -> Void
    @Environment(\.resolvedKeybindings) private var resolvedKeybindings

    var body: some ToolbarContent {
      ToolbarItem(placement: .navigation) {
        WorktreeDetailTitleView(
          title: toolbarState.title,
          onSubmit: toolbarState.title.supportsRename ? onRenameBranch : nil,
          externalRenamePrompt: externalRenamePrompt,
          onConsumeExternalRenamePrompt: onConsumeExternalRenamePrompt
        )
      }

      ToolbarItem(placement: .principal) {
        ToolbarStatusView(
          toast: toolbarState.statusToast,
          pullRequest: toolbarState.pullRequest,
          codeHost: toolbarState.codeHost
        )
        .padding(.horizontal)
      }

      ToolbarItemGroup {
        ToolbarNotificationsPopoverButton(
          groups: toolbarState.notificationGroups,
          unseenWorktreeCount: toolbarState.unseenNotificationWorktreeCount,
          onSelectNotification: onSelectNotification,
          onDismissAll: onDismissAllNotifications
        )
        if toolbarState.isUpdateAvailable {
          ToolbarUpdateButton(
            availableVersion: toolbarState.availableUpdateVersion,
            isReadyToInstall: toolbarState.isUpdateReadyToInstall,
            onActivate: onActivateUpdateButton
          )
        }
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
        toolbarState.showRunButtonInToolbar
        && (toolbarState.runScriptIsRunning || toolbarState.runScriptEnabled)
      let entries = customCommandEntries
      let inlineEntries = Array(entries.prefix(3))
      let overflowEntries = Array(entries.dropFirst(3))

      // One fixed separator in front of the whole Run + Custom Command cluster
      // keeps it distinct from the Open Editor / notification groups no matter
      // which items are hidden. Run and the custom commands share one group (no
      // spacer between them), matching the grouping before the toolbar toggles.
      if showRunButton || !inlineEntries.isEmpty || !overflowEntries.isEmpty {
        ToolbarSpacer(.fixed)
      }

      if showRunButton {
        ToolbarItem {
          RunScriptToolbarButton(
            isRunning: toolbarState.runScriptIsRunning,
            isEnabled: toolbarState.runScriptEnabled,
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
          ForEach(inlineEntries, id: \.command.id) { entry in
            customCommandButton(entry.command, index: entry.index)
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

    private var customCommandEntries: [(index: Int, command: UserCustomCommand)] {
      Array(toolbarState.customCommands.enumerated()).map { (index: $0.offset, command: $0.element) }
    }

    private func customCommandButton(_ command: UserCustomCommand, index: Int) -> some View {
      UserCustomCommandToolbarButton(
        title: command.resolvedTitle,
        systemImage: command.resolvedSystemImage,
        shortcut: customCommandShortcutDisplay(for: command),
        isEnabled: command.hasRunnableCommand,
        action: {
          onRunCustomCommand(index)
        }
      )
    }

    private func customCommandShortcutDisplay(for command: UserCustomCommand) -> String? {
      shortcutDisplay(for: LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id))
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
