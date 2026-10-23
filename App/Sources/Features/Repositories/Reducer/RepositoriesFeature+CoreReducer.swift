import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SwiftUI

extension RepositoriesFeature {
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func reduceCore(
    state: inout State,
    action: Action
  ) -> Effect<Action> {
    switch action {
    case .worktreeCreation, .worktreeLifecycle, .worktreeOrdering, .githubIntegration,
      .repositoryManagement,
      .workspaceCreation,
      .workspaceEditing:
      return .none

    case .activeAgents(.entryTapped(let id)),
      .activeAgents(.runWorkflowTapped(let id, _)):
      guard let entry = state.activeAgents.entries[id: id] else { return .none }
      if state.isShowingCanvas {
        requestCanvasFocus(.tab(entry.tabID), openedWorktreeID: entry.worktreeID, state: &state)
        return .run { _ in
          _ = await terminalClient.focusSurface(entry.worktreeID, entry.surfaceID)
        }
      }
      let isPlainFolder =
        state.repositories[id: entry.worktreeID]?.kind == .plain
      if isPlainFolder {
        state.pendingTerminalFocusWorktreeIDs.insert(entry.worktreeID)
      }
      return .run { send in
        // Focus the target surface (which selects its tab) before making the
        // terminal target visible, so it shows the right tab immediately instead
        // of flashing its previously-focused tab. Plain folders are represented
        // by their repository id, not a real worktree row, so they must select the
        // repository rather than attempting a worktree selection.
        _ = await terminalClient.focusSurface(entry.worktreeID, entry.surfaceID)
        if isPlainFolder {
          await send(.selectRepository(entry.worktreeID))
        } else {
          await send(.selectWorktree(entry.worktreeID, focusTerminal: true))
        }
      }

    case .activeAgents(.markAsReadTapped(let id)):
      guard let entry = state.activeAgents.entries[id: id] else { return .none }
      return .run { _ in
        await terminalClient.markNotificationsReadForSurface(entry.worktreeID, entry.surfaceID)
      }

    case .activeAgents:
      return .none

    case .task:
      state.snapshotPersistencePhase = .restoring
      let githubCLI = githubCLI
      let observeRateLimit = Effect<Action>.run { send in
        for await blocks in await githubCLI.rateLimitBlocks() {
          await send(.githubIntegration(.rateLimitBlocksChanged(blocks)))
        }
      }
      return .merge(
        observeRateLimit,
        .run { send in
          let pinned = await repositoryPersistence.loadPinnedWorktreeIDs()
          let archived = await repositoryPersistence.loadArchivedWorktrees()
          let lastFocused = await repositoryPersistence.loadLastFocusedWorktreeID()
          let repositoryOrderIDs = await repositoryPersistence.loadRepositoryOrderIDs()
          let worktreeOrderByRepository =
            await repositoryPersistence.loadWorktreeOrderByRepository()
          let repositorySnapshot = await repositoryPersistence.loadRepositorySnapshot()
          await send(.pinnedWorktreeIDsLoaded(pinned))
          await send(.archivedWorktreesLoaded(archived))
          await send(.repositoryOrderIDsLoaded(repositoryOrderIDs))
          await send(.worktreeOrderByRepositoryLoaded(worktreeOrderByRepository))
          await send(.lastFocusedWorktreeIDLoaded(lastFocused))
          await send(.repositorySnapshotLoaded(repositorySnapshot))
          await send(.loadPersistedRepositories)
        }
      )

    case .repositorySnapshotLoaded(let snapshot):
      let repositories = snapshot.map { snapshot in
        remoteFoldersEnabled ? snapshot : snapshot.filter { !RepositoryLocation.hasRemoteForm($0.id) }
      }
      guard let repositories, !repositories.isEmpty else {
        return .none
      }
      state.isRefreshingWorktrees = false
      let roots = repositories.map(\.location)
      let previousSelection = state.selectedWorktreeID
      let previousSelectedWorktree = state.worktree(for: previousSelection)
      let incomingRepositories = IdentifiedArray(uniqueElements: repositories)
      let repositoriesChanged = incomingRepositories != state.repositories
      _ = applyRepositories(
        repositories,
        roots: roots,
        shouldPruneArchivedWorktrees: true,
        keepsRemoteIDs: true,
        state: &state,
        animated: false
      )
      state.repositoryRoots = roots
      state.isInitialLoadComplete = true
      state.loadFailuresByID = [:]
      state.gitUnavailableRepositoryIDs = []
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let selectionChanged = selectionDidChange(
        previousSelectionID: previousSelection,
        previousSelectedWorktree: previousSelectedWorktree,
        selectedWorktreeID: state.selectedWorktreeID,
        selectedWorktree: selectedWorktree
      )
      var allEffects: [Effect<Action>] = []
      if repositoriesChanged {
        allEffects.append(.send(.delegate(.repositoriesChanged(state.repositories))))
      }
      if selectionChanged {
        allEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
      }
      return .merge(allEffects)

    case .pinnedWorktreeIDsLoaded(let pinnedWorktreeIDs):
      state.pinnedWorktreeIDs = pinnedWorktreeIDs
      return .none

    case .archivedWorktreesLoaded(let archivedWorktrees):
      state.archivedWorktrees = archivedWorktrees
      return .none

    case .setArchivedAutoDeletePeriod(let period, let initialTargets):
      state.archivedAutoDeletePeriod = period
      guard let period else { return .none }
      guard let initialTargets else { return .send(.autoDeleteExpiredArchivedWorktrees) }
      return .merge(initialTargets.map { .send(.deleteExpiredArchivedWorktree($0, period: period)) })

    case .autoDeleteExpiredArchivedWorktrees:
      guard let period = state.archivedAutoDeletePeriod else { return .none }
      return .merge(
        state.expiredArchivedWorktrees(for: period, now: now).map {
          .send(
            .deleteExpiredArchivedWorktree(
              ArchivedAutoDeleteTarget(worktreeID: $0.worktree.id, repositoryID: $0.repository.id), period: period
            ))
        })

    case .deleteExpiredArchivedWorktree(let target, let period):
      // Recheck membership immediately before entering the existing deletion path. An accepted
      // snapshot must not delete a worktree that was unarchived or removed in the meantime.
      guard state.archivedAutoDeletePeriod == period,
        state.expiredArchivedWorktrees(for: period, now: now).contains(where: {
          $0.worktree.id == target.worktreeID && $0.repository.id == target.repositoryID
        })
      else { return .none }
      @Shared(.settingsFile) var settingsFile
      let shouldDeleteBranch =
        settingsFile.global.deleteBranchOnAutomaticCleanup
        && state.prowlCreatedWorktreeIDs.contains(target.worktreeID)
      return reduceWorktreeLifecycle(
        state: &state,
        action: .deleteWorktreeConfirmed(
          target.worktreeID, target.repositoryID, deleteBranch: shouldDeleteBranch
        ))

    case .repositoryOrderIDsLoaded(let repositoryOrderIDs):
      state.repositoryOrderIDs = repositoryOrderIDs
      return .none

    case .worktreeOrderByRepositoryLoaded(let worktreeOrderByRepository):
      state.worktreeOrderByRepository = worktreeOrderByRepository
      return .none

    case .lastFocusedWorktreeIDLoaded(let lastFocusedWorktreeID):
      state.lastFocusedWorktreeID = lastFocusedWorktreeID
      if state.launchRestoreMode == .lastFocusedWorktree {
        state.shouldRestoreLastFocusedWorktree = true
      }
      return .none

    case .setOpenPanelPresented(let isPresented):
      state.isOpenPanelPresented = isPresented
      return .none

    case .loadPersistedRepositories:
      state.alert = nil
      state.isRefreshingWorktrees = false
      let knownRemoteRepositories = state.retainedRemoteRepositories
      return .run { send in
        let entries = await shownEntries(await loadPersistedRepositoryEntries())
        let roots = entries.map(\.location)
        let (repositories, failures) = await loadRepositoriesData(
          entries, knownRemoteRepositories: knownRemoteRepositories)
        await send(
          .repositoriesLoaded(
            repositories,
            failures: failures,
            roots: roots,
            animated: false,
            reusedRemoteRepositoryIDs: Self.reusedIDs(knownRemoteRepositories, in: repositories)
          )
        )
      }
      .cancellable(id: CancelID.load, cancelInFlight: true)

    case .refreshWorktrees:
      state.isRefreshingWorktrees = true
      return .send(.reloadRepositories(animated: false))

    case .reloadRepositories(let animated):
      let roots = state.repositoryRoots
      guard !roots.isEmpty else {
        state.isRefreshingWorktrees = false
        return .none
      }
      return loadRepositories(
        fallbackRoots: roots, animated: animated, knownRemoteRepositories: state.retainedRemoteRepositories)

    case .repositoriesLoaded(let loadedRepositories, let failures, let roots, let animated, let reusedIDs):
      let repositories = state.reconcilingReusedRemoteRepositories(loadedRepositories, reusedIDs: reusedIDs)
      state.isRefreshingWorktrees = false
      let wasRestoringSnapshot = state.snapshotPersistencePhase == .restoring
      state.snapshotPersistencePhase = state.snapshotPersistencePhase.afterLiveLoad(
        hasFailures: !failures.isEmpty)
      let previousSelection = state.selectedWorktreeID
      let previousSelectedWorktree = state.worktree(for: previousSelection)
      let incomingRepositories = IdentifiedArray(uniqueElements: repositories)
      let repositoriesChanged = incomingRepositories != state.repositories
      let applyResult = applyRepositories(
        repositories,
        roots: roots,
        shouldPruneArchivedWorktrees: failures.isEmpty,
        state: &state,
        animated: animated
      )
      state.repositoryRoots = roots
      state.isInitialLoadComplete = true
      let rebindChange = recordLoadFailures(failures, state: &state)
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let selectionChanged = selectionDidChange(
        previousSelectionID: previousSelection,
        previousSelectedWorktree: previousSelectedWorktree,
        selectedWorktreeID: state.selectedWorktreeID,
        selectedWorktree: selectedWorktree
      )
      var allEffects: [Effect<Action>] = [connectionHoldEffects(for: rebindChange, state: state)]
      if repositoriesChanged || wasRestoringSnapshot {
        allEffects.append(.send(.delegate(.repositoriesChanged(state.repositories))))
      }
      if selectionChanged {
        allEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
      }
      if applyResult.didPrunePinned {
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        allEffects.append(
          .run { _ in
            await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
          })
      }
      if applyResult.didPruneRepositoryOrder {
        let repositoryOrderIDs = state.repositoryOrderIDs
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveRepositoryOrderIDs(repositoryOrderIDs)
          })
      }
      if applyResult.didPruneWorktreeOrder {
        let worktreeOrderByRepository = state.worktreeOrderByRepository
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
          })
      }
      if applyResult.didPruneArchivedWorktrees {
        let archivedWorktrees = state.archivedWorktrees
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveArchivedWorktrees(archivedWorktrees)
          }
        )
      }
      if failures.isEmpty, !wasRestoringSnapshot {
        let repositories = Array(state.repositories)
        allEffects.append(
          .run { _ in
            await repositoryPersistence.saveRepositorySnapshot(repositories)
          }
        )
      }
      if state.archivedAutoDeletePeriod != nil {
        allEffects.append(.send(.autoDeleteExpiredArchivedWorktrees))
      }
      if repositoriesChanged,
        let effect = detectCodeHostsEffect(for: state.repositories)
      {
        allEffects.append(effect)
      }
      allEffects.append(refreshWorkspaceChildrenEffect(state: state))
      allEffects.append(syncRemoteRefreshSchedules(state: &state))
      return .merge(allEffects)

    case .remoteRepositoryRefreshDue(let repositoryID):
      return reduceRemoteRefreshDue(repositoryID, state: &state)

    case .remoteRepositoryRefreshed(let repositoryID, let result):
      return reduceRemoteRefreshed(repositoryID, result, state: &state)

    case .setRemoteRefreshActive(let isActive):
      return setRemoteRefreshActive(isActive, state: &state)

    case .refreshAllCustomTitles:
      // Fan out across the current repository list, reading each
      // per-repo settings file via `@Shared`. Runs in a reducer
      // effect (not in a view body), so even when the first cache
      // miss triggers a `settingsFile` write the resulting view
      // re-render can't loop back into this action.
      let repositoriesForTitleRefresh = Array(state.repositories)
      return .run { send in
        var dict: [Repository.ID: String] = [:]
        for repository in repositoriesForTitleRefresh {
          @Shared(.repositorySettings(repository.location)) var settings
          let trimmed = settings.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
          if let trimmed, !trimmed.isEmpty {
            dict[repository.id] = trimmed
          }
        }
        await send(.customTitlesLoaded(dict))
      }

    case .refreshCustomTitle(let location):
      guard let repository = state.repositories.first(where: { $0.location == location }) else {
        return .none
      }
      let repositoryID = repository.id
      return .run { send in
        @Shared(.repositorySettings(location)) var settings
        let trimmed = settings.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        await send(.customTitleUpdated(repositoryID, normalized))
      }

    case .customTitlesLoaded(let dict):
      guard state.repositoryCustomTitles != dict else { return .none }
      state.repositoryCustomTitles = dict
      return .none

    case .customTitleUpdated(let id, let title):
      if let title {
        guard state.repositoryCustomTitles[id] != title else { return .none }
        state.repositoryCustomTitles[id] = title
      } else {
        guard state.repositoryCustomTitles[id] != nil else { return .none }
        state.repositoryCustomTitles.removeValue(forKey: id)
      }
      return .none

    case .codeHostsDetected(let codeHostByRepositoryID):
      let knownIDs = Set(state.repositories.ids)
      var updated = state.codeHostByRepositoryID.filter { knownIDs.contains($0.key) }
      for (id, host) in codeHostByRepositoryID where knownIDs.contains(id) {
        updated[id] = host
      }
      state.codeHostByRepositoryID = updated
      return .none

    case .selectArchivedWorktrees:
      state.isShelfActive = false
      // Toggle: if already showing archived, return to the previous worktree.
      if state.isShowingArchivedWorktrees {
        defer { state.preArchivedWorktreeID = nil }
        if let previousID = state.preArchivedWorktreeID,
          isSelectionValid(previousID, state: state)
        {
          setSingleWorktreeSelection(previousID, state: &state, recordHistory: false)
          state.openedWorktreeIDs.insert(previousID)
          state.pendingTerminalFocusWorktreeIDs.insert(previousID)
          return .send(.delegate(.selectedWorktreeChanged(state.worktree(for: previousID))))
        }
        state.selection = nil
        state.selectedWorkspaceChildID = nil
        state.sidebarSelectedWorktreeIDs = []
        return .send(.delegate(.selectedWorktreeChanged(nil)))
      }
      // Entering archived view — remember current worktree for later restore.
      state.preArchivedWorktreeID = state.selectedWorktreeID
      recordWorktreeHistoryTransition(from: state.selectedWorktreeID, to: nil, state: &state)
      state.selection = .archivedWorktrees
      state.selectedWorkspaceChildID = nil
      state.sidebarSelectedWorktreeIDs = []
      return .send(.delegate(.selectedWorktreeChanged(nil)))

    case .selectCanvas:
      // Remember the current worktree so toggleCanvas can restore it.
      let canvasSeedWorktree = state.selectedTerminalWorktree
      state.preCanvasWorktreeID = state.selectedWorktreeID
      state.preCanvasTerminalTargetID = canvasSeedWorktree?.id
      state.isShelfActive = false
      state.selection = .canvas
      state.selectedWorkspaceChildID = nil
      state.sidebarSelectedWorktreeIDs = []
      // Canvas only renders cards for worktrees that already have a live
      // terminal surface. Normal/Shelf get the previously-focused worktree
      // opened lazily when its view mounts and calls `ensureInitialTab`;
      // Canvas mounts no such per-worktree view, so launching straight into
      // Canvas would show an empty board. Seed the surface for the worktree
      // we're entering from so at least that card appears — matching the
      // single-tab restore Normal and Shelf perform. `ensureInitialTab` is
      // idempotent, so this no-ops once the worktree already has tabs.
      return .run { _ in
        if let canvasSeedWorktree {
          await terminalClient.send(
            .ensureInitialTab(canvasSeedWorktree, runSetupScriptIfNew: false, focusing: false)
          )
        }
        await terminalClient.send(.setCanvasMode(true))
      }

    case .selectShelf:
      guard !state.isShelfActive else { return .none }
      return .send(.toggleShelf)

    case .selectTabbed:
      if state.isShowingCanvas {
        return .send(.toggleCanvas)
      }
      if state.isShowingShelf {
        return .send(.toggleShelf)
      }
      return .none

    case .setTopSegment(let segment):
      switch segment {
      case .tabbed:
        return .send(.selectTabbed)
      case .canvas:
        return .send(.selectCanvas)
      case .shelf:
        return .send(.selectShelf)
      }

    case .toggleCanvas:
      if state.isShowingCanvas {
        // Exit canvas: prefer the card focused in canvas, then the worktree
        // we came from, then the first available worktree.
        let targetID =
          terminalClient.canvasFocusedWorktreeID()
          ?? state.preCanvasTerminalTargetID
          ?? state.preCanvasWorktreeID
          ?? state.lastFocusedWorktreeID
          ?? state.orderedWorktreeRows().first?.id
        guard let targetID else { return .none }
        if state.worktree(for: targetID) == nil,
          let repository = state.repositories[id: targetID],
          repository.kind == .plain
        {
          state.pendingTerminalFocusWorktreeIDs.insert(targetID)
          return .send(.selectRepository(targetID))
        }
        return .send(.selectWorktree(targetID, focusTerminal: true))
      } else {
        // Enter canvas if there are any open worktrees.
        guard !state.orderedWorktreeRows().isEmpty else { return .none }
        return .send(.selectCanvas)
      }

    case .selectNextShelfBook:
      if state.isShowingCanvas {
        return .send(.requestCanvasCommand(.navigate(.moveRight)))
      }
      guard let book = shelfBook(atOffset: 1, state: state) else { return .none }
      return shelfBookSelectionEffect(for: book)

    case .selectPreviousShelfBook:
      if state.isShowingCanvas {
        return .send(.requestCanvasCommand(.navigate(.moveLeft)))
      }
      guard let book = shelfBook(atOffset: -1, state: state) else { return .none }
      return shelfBookSelectionEffect(for: book)

    case .selectShelfBook(let index):
      let books = state.orderedShelfBooks()
      let zeroBased = index - 1
      guard books.indices.contains(zeroBased) else { return .none }
      return shelfBookSelectionEffect(for: books[zeroBased])

    case .markWorktreeOpened(let worktreeID):
      state.openedWorktreeIDs.insert(worktreeID)
      return .none

    case .markWorktreeClosed(let worktreeID):
      // Closing the last tab of a book retires the book from the
      // Shelf. If this book was the one currently open on the
      // Shelf, move focus to the neighboring book — the one after
      // the closed book if there is one, otherwise the one before
      // — so the user lands close to where they were instead of
      // always snapping back to the first spine.
      let replacement = replacementBookAfterClosing(
        worktreeID: worktreeID,
        state: state
      )
      state.openedWorktreeIDs.remove(worktreeID)
      if let replacement {
        return shelfBookSelectionEffect(for: replacement)
      }
      return .none

    case .toggleShelf:
      if state.isShelfActive {
        state.isShelfActive = false
        return .none
      }
      // Entering Shelf requires at least one book to render.
      guard state.canEnterShelf else { return .none }
      // Shelf is mutually exclusive with Canvas / archived views: when entering
      // Shelf we need a worktree- or repository-scoped selection.
      let needsRedirect: Bool
      switch state.selection {
      case .some(.worktree), .some(.repository):
        needsRedirect = state.selectedTerminalWorktree == nil
      case .some(.canvas), .some(.archivedWorktrees), .none:
        needsRedirect = true
      }
      state.isShelfActive = true
      if !needsRedirect {
        // The current selection is the open book — make sure it's
        // registered as opened so the Shelf renders at least this
        // spine. Guards the case where `selection` was set without
        // going through `.selectWorktree` / `.selectRepository`.
        //
        // Also request terminal focus for this worktree so that
        // `ShelfOpenBookView.onAppear` forces focus onto the
        // surface (`forceAutoFocus: shouldFocusTerminal(for:)`).
        // Without this, entering Shelf via keyboard shortcut
        // leaves the first responder on the (now-dismissed) menu
        // path, and `applySurfaceActivity`'s "only refocus if the
        // current responder is a GhosttySurfaceView" guard skips
        // the surface — user can't type until a second
        // interaction (tab switch, etc.) forces focus through.
        switch state.selection {
        case .some(.worktree(let id)):
          state.openedWorktreeIDs.insert(id)
          state.pendingTerminalFocusWorktreeIDs.insert(id)
        case .some(.repository(let id))
        where state.repositories[id: id]?.kind == .plain:
          state.openedWorktreeIDs.insert(id)
          state.pendingTerminalFocusWorktreeIDs.insert(id)
        default:
          break
        }
        return .none
      }
      // Same fallback chain as `toggleCanvas`'s exit path: prefer
      // the card the user was actively focused on in Canvas so a
      // Canvas → Shelf switch opens *that* card as the active book,
      // not whatever was selected before Canvas was entered.
      let candidates = [
        terminalClient.canvasFocusedWorktreeID(), state.preCanvasTerminalTargetID,
        state.preCanvasWorktreeID, state.lastFocusedWorktreeID,
        state.orderedWorktreeRows().first?.id,
        state.orderedRepositoryIDs().first(where: { state.repositories[id: $0]?.kind == .plain }),
      ]
      let targetID = candidates.compactMap { $0 }.first {
        state.worktree(for: $0) != nil || state.repositories[id: $0]?.kind == .plain
      }
      guard let targetID else { return .none }
      if state.worktree(for: targetID) == nil,
        let repository = state.repositories[id: targetID],
        repository.kind == .plain
      {
        state.pendingTerminalFocusWorktreeIDs.insert(targetID)
        return .send(.selectRepository(targetID))
      }
      return .send(.selectWorktree(targetID, focusTerminal: true))

    case .setSidebarSelectedWorktreeIDs(let worktreeIDs):
      let validWorktreeIDs = Set(state.orderedWorktreeRows().map(\.id))
      var nextWorktreeIDs = worktreeIDs.intersection(validWorktreeIDs)
      if let selectedWorktreeID = state.selectedWorktreeID,
        validWorktreeIDs.contains(selectedWorktreeID)
      {
        nextWorktreeIDs.insert(selectedWorktreeID)
      }
      state.sidebarSelectedWorktreeIDs = nextWorktreeIDs
      return .none

    case .selectRepository(let repositoryID):
      // `inout state` cannot be captured by a closure, so use the
      // begin/end token API rather than the `interval` helper.
      let selectRepoToken = repositoriesLogger.beginInterval("reducer.selectRepository")
      defer { repositoriesLogger.endInterval(selectRepoToken) }
      guard let repositoryID, state.repositories[id: repositoryID] != nil else { return .none }
      recordWorktreeHistoryTransition(from: state.selectedWorktreeID, to: nil, state: &state)
      state.selection = .repository(repositoryID)
      state.selectedWorkspaceChildID = nil
      state.sidebarSelectedWorktreeIDs = []
      if state.repositories[id: repositoryID]?.kind == .plain {
        // Plain folder selection opens the folder as a Shelf book.
        state.openedWorktreeIDs.insert(repositoryID)
      }
      return .send(.delegate(.selectedWorktreeChanged(state.selectedTerminalWorktree)))

    case .openWorkspaceChild(let childID):
      guard let child = state.allResolvedWorkspaceChildren().first(where: { $0.id == childID }),
        let workspaceWorktree = state.repositories[id: child.workspaceID]?.terminalWorktree
      else {
        return .none
      }
      recordWorktreeHistoryTransition(from: state.selectedWorktreeID, to: nil, state: &state)
      state.selection = .repository(child.workspaceID)
      state.selectedWorkspaceChildID = child.id
      state.sidebarSelectedWorktreeIDs = []
      state.openedWorktreeIDs.insert(child.workspaceID)
      state.pendingTerminalFocusWorktreeIDs.insert(child.workspaceID)
      return .merge(
        .send(.delegate(.selectedWorktreeChanged(workspaceWorktree))),
        .run { _ in
          await terminalClient.send(
            .focusOrCreateTabInDirectory(
              workspaceWorktree,
              directory: child.workingDirectory,
              title: child.repositoryName
            ))
        }
      )

    case .selectWorktree(let worktreeID, let focusTerminal, let recordHistory):
      let selectWtToken = repositoriesLogger.beginInterval("reducer.selectWorktree")
      defer { repositoriesLogger.endInterval(selectWtToken) }
      setSingleWorktreeSelection(worktreeID, state: &state, recordHistory: recordHistory)
      if focusTerminal, let worktreeID {
        state.pendingTerminalFocusWorktreeIDs.insert(worktreeID)
      }
      if let worktreeID {
        state.openedWorktreeIDs.insert(worktreeID)
      }
      let selectedWorktree = state.worktree(for: worktreeID)
      return .send(.delegate(.selectedWorktreeChanged(selectedWorktree)))

    case .newTerminalTab(let worktreeID):
      guard let worktree = state.worktree(for: worktreeID) else { return .none }
      // Remote tabs come with the remote launcher (docs-ai 084 C3).
      guard let worktreeDirectory = worktree.localURL else {
        let reason = FeatureUnavailableReason.remoteFolder(.terminalTab)
        return .send(.showToast(.warning(reason.message)))
      }
      // Pin the new tab's cwd to the worktree root: Ghostty's default new-tab
      // behavior inherits the focused surface's cwd, which is wrong when the
      // user targets a worktree from the sidebar.
      let createTab: Effect<Action> = .run { _ in
        await terminalClient.send(
          .createTabInDirectory(worktree, directory: worktreeDirectory))
      }
      // Canvas focuses and reveals the new card itself when it appears, like
      // every other tab created while Canvas is showing.
      if state.isShowingCanvas { return createTab }
      return .merge(.send(.selectWorktree(worktreeID, focusTerminal: true)), createTab)

    case .newTerminalTabCreatedInCanvas(let worktreeID, let tabID):
      // A plain folder's terminal target is its synthesized worktree, so an
      // undo restoring one of its tabs must pass this guard too.
      guard state.isShowingCanvas, state.terminalWorktree(for: worktreeID) != nil else { return .none }
      requestCanvasFocus(.tab(tabID), viewport: .reveal, openedWorktreeID: worktreeID, state: &state)
      return .none

    case .focusCanvasRepository(let repositoryID):
      guard state.isShowingCanvas,
        let worktree = state.canvasNavigationWorktree(forRepositoryID: repositoryID)
      else {
        return .none
      }
      requestCanvasFocus(.worktree(worktree.id), openedWorktreeID: worktree.id, state: &state)
      return .run { _ in
        await terminalClient.send(
          .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false))
      }

    case .focusCanvasWorktree(let worktreeID):
      guard state.isShowingCanvas,
        let worktree = state.worktree(for: worktreeID)
      else {
        return .none
      }
      requestCanvasFocus(.worktree(worktree.id), openedWorktreeID: worktree.id, state: &state)
      return .run { _ in
        await terminalClient.send(
          .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false))
      }

    case .selectNextWorktree:
      if state.isShowingCanvas {
        return .send(.requestCanvasCommand(.navigate(.moveDown)))
      }
      // In Shelf, the vertical arrow pair maps to tab navigation
      // within the open book — horizontal (← / →) is already book
      // navigation, so the two axes match the Shelf layout.
      if state.isShelfActive, let worktree = state.selectedTerminalWorktree {
        return .run { _ in
          await terminalClient.send(.performBindingAction(worktree, action: "next_tab"))
        }
      }
      guard let id = state.worktreeID(byOffset: 1) else { return .none }
      return .send(.selectWorktree(id, focusTerminal: true))

    case .selectPreviousWorktree:
      if state.isShowingCanvas {
        return .send(.requestCanvasCommand(.navigate(.moveUp)))
      }
      if state.isShelfActive, let worktree = state.selectedTerminalWorktree {
        return .run { _ in
          await terminalClient.send(.performBindingAction(worktree, action: "previous_tab"))
        }
      }
      guard let id = state.worktreeID(byOffset: -1) else { return .none }
      return .send(.selectWorktree(id, focusTerminal: true))

    case .consumeCanvasFocusRequest(let id):
      if state.pendingCanvasFocusRequest?.id == id {
        state.pendingCanvasFocusRequest = nil
      }
      return .none

    case .requestCanvasCommand(let command):
      state.nextCanvasCommandRequestID += 1
      state.pendingCanvasCommandRequest = CanvasCommandRequest(
        id: state.nextCanvasCommandRequestID,
        command: command
      )
      return .none

    case .consumeCanvasCommandRequest(let id):
      if state.pendingCanvasCommandRequest?.id == id {
        state.pendingCanvasCommandRequest = nil
        state.lastPerformedCanvasCommandRequestID = id
      }
      return .none

    case .dropCanvasCommandRequest(let id):
      if state.pendingCanvasCommandRequest?.id == id {
        state.pendingCanvasCommandRequest = nil
      }
      return .none

    case .worktreeHistoryBack:
      return navigateWorktreeHistory(direction: .backward, state: &state)

    case .worktreeHistoryForward:
      return navigateWorktreeHistory(direction: .forward, state: &state)

    case .revealSelectedWorktreeInSidebar:
      guard let worktreeID = state.selectedWorktreeID,
        let repositoryID = state.repositoryID(containing: worktreeID)
      else { return .none }
      state.$collapsedRepositoryIDs.withLock {
        $0.removeAll { $0 == repositoryID }
      }
      state.nextPendingSidebarRevealID += 1
      state.pendingSidebarReveal = .init(
        id: state.nextPendingSidebarRevealID,
        worktreeID: worktreeID
      )
      return .none

    case .consumePendingSidebarReveal(let revealID):
      guard state.pendingSidebarReveal?.id == revealID else { return .none }
      state.pendingSidebarReveal = nil
      return .none

    case .requestRenameBranchPrompt(let worktreeID):
      guard let worktree = state.worktree(for: worktreeID) else { return .none }
      state.nextPendingRenameBranchRequestID += 1
      state.pendingRenameBranchRequest = .init(
        id: state.nextPendingRenameBranchRequestID,
        worktreeID: worktreeID,
        currentName: worktree.name
      )
      return .none

    case .consumePendingRenameBranchRequest(let requestID):
      guard state.pendingRenameBranchRequest?.id == requestID else { return .none }
      state.pendingRenameBranchRequest = nil
      return .none

    case .requestRenameBranch(let worktreeID, let branchName):
      guard let worktree = state.worktree(for: worktreeID) else { return .none }
      let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        state.alert = messageAlert(
          title: String(localized: "Branch name required"),
          message: String(localized: "Enter a branch name to rename.")
        )
        return .none
      }
      guard !trimmed.contains(where: \.isWhitespace) else {
        state.alert = messageAlert(
          title: String(localized: "Branch name invalid"),
          message: String(localized: "Branch names can't contain spaces.")
        )
        return .none
      }
      if trimmed == worktree.name {
        return .none
      }
      analyticsClient.capture("branch_renamed", nil)
      let repositoryHost = repositoryHost
      let worktreeLocation = worktree.location
      return .run { send in
        do {
          try await repositoryHost.renameBranch(in: worktreeLocation, to: trimmed)
          await send(.reloadRepositories(animated: true))
        } catch {
          await send(
            .presentAlert(
              title: String(localized: "Unable to rename branch"),
              message: error.localizedDescription
            )
          )
        }
      }

    case .remoteHostRebindRequested(let hostProfileID):
      return reduceRemoteHostRebindRequested(hostProfileID)

    case .remoteHostRebindResolved(let target):
      state.alert = rebindAlert(for: target)
      return .none

    case .remoteHostRebindFailed(let message):
      state.alert = messageAlert(
        title: String(localized: "Prowl could not rebind the host"), message: message)
      return .none

    case .alert(.presented(.rebindRemoteHost(let hostProfileID, let key))):
      state.alert = nil
      return reduceRebindRemoteHost(hostProfileID, to: key)

    case .alert(.presented(.confirmRemoveFailedRepository(let repositoryID))):
      return .send(.repositoryManagement(.removeFailedRepository(repositoryID)))

    case .remoteHostRebound(let hostProfileID):
      return reduceRemoteHostRebound(hostProfileID, state: &state)

    case .addRemoteFolderRequested:
      guard remoteFoldersEnabled else { return .none }
      @Shared(.hostProfiles) var hostProfiles: [HostProfile]
      state.addRemoteFolder = AddRemoteFolderFeature.State(hostProfiles: hostProfiles)
      return .none

    case .addRemoteFolder(.presented(.delegate(.hostRebound(let hostProfileID)))):
      return .send(.remoteHostRebound(hostProfileID))

    case .addRemoteFolder(.presented(.delegate(.cancel))):
      state.addRemoteFolder = nil
      return .none

    case .addRemoteFolder(.presented(.delegate(.added(let location, let kind)))):
      state.addRemoteFolder = nil
      return .send(.repositoryManagement(.openRemoteRepository(location, kind: kind)))

    case .addRemoteFolder:
      return .none

    case .worktreeCreationPrompt(.presented(.delegate(.cancel))):
      return .send(.worktreeCreation(.promptCanceled))

    case .worktreeCreationPrompt(
      .presented(.delegate(.submit(let repositoryID, let branchName, let baseRef, let placement)))
    ):
      return .send(
        .worktreeCreation(
          .startPromptedWorktreeCreation(
            repositoryID: repositoryID,
            branchName: branchName,
            baseRef: baseRef,
            placement: placement
          )
        )
      )

    case .worktreeCreationPrompt(.dismiss):
      return .send(.worktreeCreation(.promptDismissed))

    case .worktreeCreationPrompt:
      return .none

    case .workspaceEditor(.presented(.delegate(.cancel))):
      if state.workspaceEditor?.mode.isEditing == true {
        return .send(.workspaceEditing(.promptCanceled))
      }
      return .send(.workspaceCreation(.promptCanceled))

    case .workspaceEditor(.presented(.delegate(.submit(.create(let draft))))):
      return .send(.workspaceCreation(.createWorkspace(draft)))

    case .workspaceEditor(.presented(.delegate(.submit(.update(let request))))):
      return .send(.workspaceEditing(.saveWorkspace(request)))

    case .workspaceEditor(.dismiss):
      if state.workspaceEditor?.mode.isEditing == true {
        return .send(.workspaceEditing(.promptDismissed))
      }
      return .send(.workspaceCreation(.promptDismissed))

    case .workspaceEditor:
      return .none

    case .alert(.presented(.confirmArchiveWorktree(let worktreeID, let repositoryID))):
      return .send(.worktreeLifecycle(.archiveWorktreeConfirmed(worktreeID, repositoryID)))

    case .alert(.presented(.confirmArchiveWorktrees(let targets))):
      return .merge(
        targets.map { target in
          .send(
            .worktreeLifecycle(.archiveWorktreeConfirmed(target.worktreeID, target.repositoryID)))
        }
      )

    case .alert(.presented(.confirmForceDeleteBranch(let request))):
      return .send(.worktreeLifecycle(.forceDeleteBranchConfirmed(request)))

    case .alert(.presented(.confirmRemoveRepository(let repositoryID))):
      guard let repository = state.repositories[id: repositoryID] else {
        return .none
      }
      if state.removingRepositoryIDs.contains(repository.id) {
        return .none
      }
      state.alert = nil
      state.removingRepositoryIDs.insert(repository.id)
      let selectionWasRemoved =
        state.selectedWorktreeID.map { id in
          repository.worktrees.contains(where: { $0.id == id })
        } ?? false
      return .send(
        .repositoryManagement(
          .repositoryRemoved(repository.id, selectionWasRemoved: selectionWasRemoved)))

    case .alert(
      .presented(
        .confirmWorkspaceRootDeletion(let repositoryID, let rootPath, let selectionWasRemoved))):
      state.alert = nil
      let rootURL = URL(fileURLWithPath: rootPath)
      return .run { send in
        ProjectWorkspace.removeWorkspaceFolder(at: rootURL)
        await send(
          .repositoryManagement(
            .repositoryRemoved(repositoryID, selectionWasRemoved: selectionWasRemoved)))
      }

    case .alert(
      .presented(.keepWorkspaceFolderAfterCleanupFailure(let repositoryID, let selectionWasRemoved))
    ):
      state.alert = nil
      return .send(
        .repositoryManagement(
          .repositoryRemoved(repositoryID, selectionWasRemoved: selectionWasRemoved)))

    case .showRepositoryLoadFailure(let id):
      guard let detail = state.loadFailuresByID[id] else { return .none }
      let unavailable = state.gitUnavailableRepositoryIDs.contains(id)
      state.alert = AlertState {
        TextState(
          unavailable ? String(localized: "Git is unavailable") : String(localized: "Unable to read repository"))
      } actions: {
        ButtonState(action: .retryRepositoryLoad) { TextState(String(localized: "Retry")) }
        ButtonState(action: .copyRepositoryLoadFailure("\(id)\n\n\(detail)")) {
          TextState(String(localized: "Copy Details"))
        }
        ButtonState(role: .cancel) { TextState(String(localized: "OK")) }
      } message: {
        TextState(
          unavailable
            ? detail
            : String(localized: "Check this folder's permissions and Git configuration, then retry.") + "\n\n" + detail)
      }
      return .none

    case .alert(.presented(.retryRepositoryLoad)):
      state.alert = nil
      return .send(.refreshWorktrees)

    case .alert(.presented(.copyRepositoryLoadFailure(let detail))):
      return .run { _ in
        await MainActor.run {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(detail, forType: .string)
        }
      }

    case .presentAlert(let title, let message):
      state.alert = messageAlert(title: title, message: message)
      return .none

    case .showToast(let toast):
      state.statusToast = toast
      switch toast {
      case .inProgress:
        return .cancel(id: CancelID.toastAutoDismiss)
      case .success, .warning:
        return .run { send in
          try? await ContinuousClock().sleep(for: .seconds(3))
          await send(.dismissToast)
        }
        .cancellable(id: CancelID.toastAutoDismiss, cancelInFlight: true)
      }

    case .dismissToast:
      state.statusToast = nil
      return .none

    case .worktreeInfoEvent(let event):
      switch event {
      case .branchChanged(let worktreeID):
        guard let worktree = state.worktree(for: worktreeID) else {
          return .none
        }
        let worktreeLocation = worktree.location
        let repositoryHost = repositoryHost
        return .run { send in
          if let name = await repositoryHost.branchName(of: worktreeLocation) {
            await send(.worktreeBranchNameLoaded(worktreeID: worktreeID, name: name))
          }
        }
      case .filesChanged(let worktreeID):
        guard let worktree = state.worktree(for: worktreeID),
          worktree.availability(of: .lineCounts).isAvailable
        else {
          return .none
        }
        @Shared(.repositorySettings(worktree.repositoryLocation)) var repositorySettings
        guard repositorySettings.observesLineDiffsAutomatically else {
          return .none
        }
        let worktreeLocation = worktree.location
        let repositoryHost = repositoryHost
        let previousLineChanges = normalizedLineChanges(state.worktreeInfoByID[worktreeID])
        return .run { send in
          if let changes = await repositoryHost.lineChanges(in: worktreeLocation) {
            let nextLineChanges = normalizedLineChanges(changes)
            guard nextLineChanges != previousLineChanges else {
              return
            }
            await send(
              .worktreeLineChangesLoaded(
                worktreeID: worktreeID,
                changes: changes
              )
            )
          }
        }
      case .repositoryWorktreesChanged:
        return .send(.reloadRepositories(animated: true))
      case .repositoryRemoteConfigurationChanged(let location):
        guard
          let changedRoot = location.localURL?.standardizedFileURL,
          let repository = state.repositories.first(where: {
            $0.location.localURL?.standardizedFileURL == changedRoot
          })
        else {
          return .none
        }
        return remoteConfigurationChanged(repository, state: &state)
      case .repositoryPullRequestRefresh(let location, let worktreeIDs):
        return .send(
          .githubIntegration(
            .repositoryPullRequestRefreshRequested(
              repositoryLocation: location,
              worktreeIDs: worktreeIDs
            )
          )
        )
      case .plainRepositoryBecameGitRepository:
        return .send(.reloadRepositories(animated: true))
      }

    case .worktreeBranchNameLoaded(let worktreeID, let name):
      updateWorktreeName(worktreeID, name: name, state: &state)
      return .none

    case .worktreeLineChangesLoaded(let worktreeID, let changes):
      updateWorktreeLineChanges(
        worktreeID: worktreeID,
        changes: changes,
        state: &state
      )
      return .none

    case .workspaceChildrenInfoLoaded(let updates):
      // An in-flight refresh can land after a reload changed the child set;
      // only merge updates that still belong to a current workspace child.
      let validIDs = Set(state.allResolvedWorkspaceChildren().map(\.id))
      applyWorkspaceChildrenInfo(updates.filter { validIDs.contains($0.id) }, state: &state)
      return .none

    case .alert(.dismiss):
      dismissCurrentForceDeleteBranchRequest(state: &state)
      return .none

    case .alert:
      return .none

    case .delegate:
      return .none
    }
  }
}
