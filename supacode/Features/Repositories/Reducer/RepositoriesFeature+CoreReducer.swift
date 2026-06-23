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
      .workspaceCreation:
      return .none

    case .activeAgents(.entryTapped(let id)):
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

    case .activeAgents:
      return .none

    case .task:
      state.snapshotPersistencePhase = .restoring
      return .run { send in
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

    case .repositorySnapshotLoaded(let repositories):
      guard let repositories, !repositories.isEmpty else {
        return .none
      }
      state.isRefreshingWorktrees = false
      let roots = repositories.map(\.rootURL)
      let previousSelection = state.selectedWorktreeID
      let previousSelectedWorktree = state.worktree(for: previousSelection)
      let incomingRepositories = IdentifiedArray(uniqueElements: repositories)
      let repositoriesChanged = incomingRepositories != state.repositories
      _ = applyRepositories(
        repositories,
        roots: roots,
        shouldPruneArchivedWorktrees: true,
        state: &state,
        animated: false
      )
      state.repositoryRoots = roots
      state.isInitialLoadComplete = true
      state.loadFailuresByID = [:]
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

    case .setArchivedAutoDeletePeriod(let period):
      state.archivedAutoDeletePeriod = period
      guard period != nil else { return .none }
      return .send(.autoDeleteExpiredArchivedWorktrees)

    case .autoDeleteExpiredArchivedWorktrees:
      guard let period = state.archivedAutoDeletePeriod else {
        return .none
      }
      let cutoff = now.addingTimeInterval(-Double(period.rawValue) * secondsPerDay)
      let expiredEntries = state.archivedWorktrees.filter { $0.archivedAt <= cutoff }
      guard !expiredEntries.isEmpty else {
        return .none
      }
      @Shared(.settingsFile) var settingsFile
      var deleteEffects: [Effect<Action>] = []
      for entry in expiredEntries {
        guard
          let (worktree, repository) = findWorktreeAndRepository(
            worktreeID: entry.id,
            state: state
          ),
          !state.isMainWorktree(worktree),
          !state.deletingWorktreeIDs.contains(entry.id)
        else {
          continue
        }
        let shouldDeleteBranch =
          settingsFile.global.deleteBranchOnAutomaticCleanup
          && state.prowlCreatedWorktreeIDs.contains(worktree.id)
        deleteEffects.append(
          .send(
            .worktreeLifecycle(
              .deleteWorktreeConfirmed(
                worktree.id,
                repository.id,
                deleteBranch: shouldDeleteBranch
              ))
          )
        )
      }
      guard !deleteEffects.isEmpty else {
        return .none
      }
      return .merge(deleteEffects)

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
      return .run { send in
        let entries = await loadPersistedRepositoryEntries()
        let roots = entries.map { URL(fileURLWithPath: $0.path) }
        let (repositories, failures) = await loadRepositoriesData(entries)
        await send(
          .repositoriesLoaded(
            repositories,
            failures: failures,
            roots: roots,
            animated: false
          )
        )
      }
      .cancellable(id: CancelID.load, cancelInFlight: true)

    case .refreshWorktrees:
      state.isRefreshingWorktrees = true
      return .send(.reloadRepositories(animated: false))

    case .reloadRepositories(let animated):
      state.alert = nil
      let roots = state.repositoryRoots
      guard !roots.isEmpty else {
        state.isRefreshingWorktrees = false
        return .none
      }
      return loadRepositories(fallbackRoots: roots, animated: animated)

    case .repositoriesLoaded(let repositories, let failures, let roots, let animated):
      state.isRefreshingWorktrees = false
      let wasRestoringSnapshot = state.snapshotPersistencePhase == .restoring
      if failures.isEmpty, state.snapshotPersistencePhase != .active {
        state.snapshotPersistencePhase = .active
      }
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
      state.loadFailuresByID = Dictionary(
        failures.map { ($0.rootID, $0.message) },
        uniquingKeysWith: { first, _ in first }
      )
      let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
      let selectionChanged = selectionDidChange(
        previousSelectionID: previousSelection,
        previousSelectedWorktree: previousSelectedWorktree,
        selectedWorktreeID: state.selectedWorktreeID,
        selectedWorktree: selectedWorktree
      )
      var allEffects: [Effect<Action>] = []
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
      return .merge(allEffects)

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
          @Shared(.repositorySettings(repository.rootURL)) var settings
          let trimmed = settings.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
          if let trimmed, !trimmed.isEmpty {
            dict[repository.id] = trimmed
          }
        }
        await send(.customTitlesLoaded(dict))
      }

    case .refreshCustomTitle(let rootURL):
      guard let repository = state.repositories.first(where: { $0.rootURL == rootURL }) else {
        return .none
      }
      let repositoryID = repository.id
      return .run { send in
        @Shared(.repositorySettings(rootURL)) var settings
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
      guard !state.orderedWorktreeRows().isEmpty else { return .none }
      // Shelf is mutually exclusive with Canvas / archived views: when entering
      // Shelf we need a worktree- or repository-scoped selection.
      let needsRedirect: Bool
      switch state.selection {
      case .some(.worktree), .some(.repository):
        needsRedirect = false
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
        let workspaceRepository = state.repositories[id: child.workspaceID]
      else {
        return .none
      }
      recordWorktreeHistoryTransition(from: state.selectedWorktreeID, to: nil, state: &state)
      state.selection = .repository(child.workspaceID)
      state.selectedWorkspaceChildID = child.id
      state.sidebarSelectedWorktreeIDs = []
      state.openedWorktreeIDs.insert(child.workspaceID)
      state.pendingTerminalFocusWorktreeIDs.insert(child.workspaceID)
      let workspaceWorktree = Worktree(
        id: workspaceRepository.id,
        name: workspaceRepository.name,
        detail: workspaceRepository.rootURL.path(percentEncoded: false),
        workingDirectory: workspaceRepository.rootURL,
        repositoryRootURL: workspaceRepository.rootURL
      )
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
      guard state.worktree(for: worktreeID) != nil else { return .none }
      state.nextPendingRenameBranchRequestID += 1
      state.pendingRenameBranchRequest = .init(
        id: state.nextPendingRenameBranchRequestID,
        worktreeID: worktreeID
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
          title: "Branch name required",
          message: "Enter a branch name to rename."
        )
        return .none
      }
      guard !trimmed.contains(where: \.isWhitespace) else {
        state.alert = messageAlert(
          title: "Branch name invalid",
          message: "Branch names can't contain spaces."
        )
        return .none
      }
      if trimmed == worktree.name {
        return .none
      }
      analyticsClient.capture("branch_renamed", nil)
      return .run { send in
        do {
          try await gitClient.renameBranch(worktree.workingDirectory, trimmed)
          await send(.reloadRepositories(animated: true))
        } catch {
          await send(
            .presentAlert(
              title: "Unable to rename branch",
              message: error.localizedDescription
            )
          )
        }
      }

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

    case .workspaceCreationPrompt(.presented(.delegate(.cancel))):
      return .send(.workspaceCreation(.promptCanceled))

    case .workspaceCreationPrompt(.presented(.delegate(.openBootstrapSettings))):
      return .send(.delegate(.openBootstrapSettings))

    case .workspaceCreationPrompt(.presented(.delegate(.baseRefSourceChanged(let repositoryID)))):
      return .send(.workspaceCreation(.refreshBaseRefs(repositoryID)))

    case .workspaceCreationPrompt(.presented(.delegate(.submit(let draft)))):
      return .send(.workspaceCreation(.createWorkspace(draft)))

    case .workspaceCreationPrompt(.dismiss):
      return .send(.workspaceCreation(.promptDismissed))

    case .workspaceCreationPrompt:
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
        let worktreeURL = worktree.workingDirectory
        let gitClient = gitClient
        return .run { send in
          if let name = await gitClient.branchName(worktreeURL) {
            await send(.worktreeBranchNameLoaded(worktreeID: worktreeID, name: name))
          }
        }
      case .filesChanged(let worktreeID):
        guard let worktree = state.worktree(for: worktreeID) else {
          return .none
        }
        @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
        guard repositorySettings.observesLineDiffsAutomatically else {
          return .none
        }
        let worktreeURL = worktree.workingDirectory
        let gitClient = gitClient
        let previousLineChanges = normalizedLineChanges(state.worktreeInfoByID[worktreeID])
        return .run { send in
          if let changes = await gitClient.lineChanges(worktreeURL) {
            let nextLineChanges = normalizedLineChanges(
              added: changes.added, removed: changes.removed)
            guard !lineChangesEqual(nextLineChanges, previousLineChanges) else {
              return
            }
            await send(
              .worktreeLineChangesLoaded(
                worktreeID: worktreeID,
                added: changes.added,
                removed: changes.removed
              )
            )
          }
        }
      case .repositoryWorktreesChanged:
        return .send(.reloadRepositories(animated: true))
      case .repositoryRemoteConfigurationChanged(let repositoryRootURL):
        guard
          let repository = state.repositories.first(where: {
            $0.rootURL.standardizedFileURL == repositoryRootURL.standardizedFileURL
          })
        else {
          return .none
        }
        let repositories = IdentifiedArrayOf(uniqueElements: [repository])
        var effects: [Effect<Action>] = []
        let worktreeIDs = repository.worktrees.map(\.id)
        if repository.capabilities.supportsPullRequests, !worktreeIDs.isEmpty {
          effects.append(
            .send(
              .githubIntegration(
                .repositoryPullRequestRefreshRequested(
                  repositoryRootURL: repository.rootURL,
                  worktreeIDs: worktreeIDs
                )
              ))
          )
        }
        if let effect = detectCodeHostsEffect(for: repositories, includeUnknown: true) {
          effects.append(effect)
        }
        return effects.isEmpty ? .none : .concatenate(effects)
      case .repositoryPullRequestRefresh(let repositoryRootURL, let worktreeIDs):
        return .send(
          .githubIntegration(
            .repositoryPullRequestRefreshRequested(
              repositoryRootURL: repositoryRootURL,
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

    case .worktreeLineChangesLoaded(let worktreeID, let added, let removed):
      updateWorktreeLineChanges(
        worktreeID: worktreeID,
        added: added,
        removed: removed,
        state: &state
      )
      return .none

    case .workspaceChildrenInfoLoaded(let updates):
      applyWorkspaceChildrenInfo(updates, state: &state)
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
