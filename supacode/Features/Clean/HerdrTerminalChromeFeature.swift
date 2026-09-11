import ComposableArchitecture
import Foundation

private nonisolated let herdrTerminalChromeLogger = SupaLogger("HerdrTerminalChrome")

@Reducer
internal struct HerdrTerminalChromeFeature {
  @ObservableState
  internal struct State: Equatable {
    internal enum Connection: Equatable {
      case hidden
      case connecting
      case connected
      case failed
    }

    internal var connection: Connection = .hidden
    internal var snapshot = HerdrSessionSnapshot.empty
    internal var selectedWorkspaceID: String?
    internal var selectedTabID: String?
    internal var selectedPaneID: String?
    internal var pendingFocus: FocusTarget?
    internal var focusRollback: FocusSelection?
    internal var pendingMutation: Mutation?
    internal var closeConfirmation: CloseConfirmation?
    internal var mutationError: HerdrTerminalChromeFailure?
    internal var refreshGeneration: UInt64 = 0
    internal var subscribedPaneIDs: Set<String> = []
    internal var pendingPaneExitIDs: Set<String> = []
    internal var subscriptionAwaitingSnapshot = false
    internal var mutationGeneration: UInt64 = 0

    internal var isVisible: Bool {
      connection == .connected
    }
  }

  internal struct FocusSelection: Equatable, Sendable {
    internal let workspaceID: String?
    internal let tabID: String?
    internal let paneID: String?
  }

  internal enum FocusTarget: Equatable, Sendable {
    case workspace(String)
    case tab(String)
    case pane(String)

    internal var id: String {
      switch self {
      case .workspace(let id), .tab(let id), .pane(let id):
        return id
      }
    }
  }

  internal enum Mutation: Equatable, Sendable {
    case createWorkspace
    case createTab(workspaceID: String, label: String?, sourceTabID: String?)
    case renameTab(tabID: String, label: String?)
    case moveTab(tabID: String, insertIndex: Int)
    case closeTab(tabID: String, workspaceID: String, isLastTab: Bool)
    case closeWorkspace(workspaceID: String)
  }

  internal struct CloseConfirmation: Equatable, Sendable {
    internal let workspaceID: String
  }

  internal enum MutationResult: Equatable, Sendable {
    case success
    case failure(HerdrTerminalChromeFailure)
  }

  internal enum DelegateAction: Equatable {
    case compatibilityFailure(HerdrSocketError)
  }

  internal enum FocusResult: Equatable {
    case success
    case failure(HerdrTerminalChromeFailure)
  }

  internal enum Action: Equatable {
    case foregroundChanged(Bool)
    case subscriptionPrepared(Set<String>)
    case snapshotResponse(Result<HerdrSessionSnapshot, HerdrTerminalChromeFailure>)
    case eventStream(HerdrEventStreamState)
    case debouncedRefresh
    case refreshResponseWithGeneration(
      UInt64,
      Result<HerdrSessionSnapshot, HerdrTerminalChromeFailure>
    )
    case focusWorkspaceTapped(String)
    case focusTabTapped(String)
    case focusPaneTapped(String)
    case focusResponse(FocusResult)
    case focusConfirmationTimedOut(FocusTarget)
    case herdrNavigationKeyPressed
    case newWorkspaceRequested
    case newTabRequested(workspaceID: String, label: String?, sourceTabID: String?)
    case renameTabRequested(tabID: String, label: String)
    case resetTabNameRequested(String)
    case moveTabRequested(tabID: String, insertIndex: Int)
    case closeTabRequested(tabID: String, workspaceID: String)
    case closeConfirmationConfirmed
    case closeConfirmationCancelled
    case mutationErrorDismissed
    case mutationResponse(UInt64, MutationResult)
    case delegate(DelegateAction)
    case stop
  }

  nonisolated private enum CancelID: Hashable, Sendable {
    case lifecycle
    case refreshDebounce
    case refresh
    case focus
    case focusConfirmation
    case mutation
  }

  private static let immediateRefreshEvents: Set<String> = [
    "workspace_created",
    "workspace_closed",
    "workspace_moved",
    "workspace_reordered",
    "workspace_metadata_updated",
    "worktree_created",
    "worktree_opened",
    "worktree_removed",
    "tab_created",
    "tab_closed",
    "tab_moved",
    "pane_created",
    "pane_closed",
    "pane_exited",
    "pane_moved",
    "layout_updated",
  ]
  private static let focusEvents: Set<String> = [
    "workspace_focused",
    "tab_focused",
    "pane_focused",
  ]
  private static let focusConfirmationTimeout = Duration.milliseconds(250)

  internal static func shouldRefreshImmediately(for eventName: String) -> Bool {
    immediateRefreshEvents.contains(eventName.replacing(".", with: "_"))
  }

  internal static func paneSetRequiresLifecycleRestart(
    subscribedPaneIDs: Set<String>,
    snapshotPaneIDs: Set<String>
  ) -> Bool {
    subscribedPaneIDs != snapshotPaneIDs
  }

  internal static func snapshotByRemovingPanes(
    _ snapshot: HerdrSessionSnapshot,
    paneIDs: Set<String>
  ) -> HerdrSessionSnapshot {
    let panes = snapshot.panes.filter { !paneIDs.contains($0.id) }
    guard panes.count != snapshot.panes.count else { return snapshot }

    let tabIDs = Set(panes.map(\.tabID))
    let tabs = snapshot.tabs.filter { tabIDs.contains($0.id) }
    let workspaceIDs = Set(tabs.map(\.workspaceID))
    let workspaces = snapshot.workspaces.filter { workspaceIDs.contains($0.id) }
    let layouts = snapshot.layouts.compactMap { layout -> HerdrLayout? in
      guard tabIDs.contains(layout.tabID), workspaceIDs.contains(layout.workspaceID) else { return nil }
      return HerdrLayout(
        workspaceID: layout.workspaceID,
        tabID: layout.tabID,
        zoomed: layout.zoomed,
        focusedPaneID: layout.focusedPaneID.flatMap { paneIDs.contains($0) ? nil : $0 },
        panes: layout.panes.filter { !paneIDs.contains($0.paneID) },
        splits: layout.splits
      )
    }
    let agents = snapshot.agents.filter { agent in
      if let paneID = agent.paneID { return !paneIDs.contains(paneID) }
      if let tabID = agent.tabID { return tabIDs.contains(tabID) }
      if let workspaceID = agent.workspaceID { return workspaceIDs.contains(workspaceID) }
      return true
    }
    return HerdrSessionSnapshot(
      version: snapshot.version,
      protocolVersion: snapshot.protocolVersion,
      focusedWorkspaceID: snapshot.focusedWorkspaceID.flatMap {
        workspaceIDs.contains($0) ? $0 : nil
      },
      focusedTabID: snapshot.focusedTabID.flatMap { tabIDs.contains($0) ? $0 : nil },
      focusedPaneID: snapshot.focusedPaneID.flatMap { paneIDs.contains($0) ? nil : $0 },
      workspaces: workspaces,
      tabs: tabs,
      panes: panes,
      layouts: layouts,
      agents: agents
    )
  }

  private func projectPendingPaneExits(_ state: inout State) {
    state.snapshot = Self.snapshotByRemovingPanes(state.snapshot, paneIDs: state.pendingPaneExitIDs)
    state.selectedWorkspaceID = reconciledSelection(
      serverFocused: state.snapshot.focusedWorkspaceID,
      validIDs: Set(state.snapshot.workspaces.map(\.id))
    )
    state.selectedTabID = reconciledSelection(
      serverFocused: state.snapshot.focusedTabID,
      validIDs: Set(state.snapshot.tabs.map(\.id))
    )
    state.selectedPaneID = reconciledSelection(
      serverFocused: state.snapshot.focusedPaneID,
      validIDs: Set(state.snapshot.panes.map(\.id))
    )
  }

  private func applyPaneExit(_ state: inout State, event: HerdrEventEnvelope) {
    guard let paneID = event.focus?.paneID,
      state.snapshot.panes.contains(where: { $0.id == paneID })
    else { return }
    state.pendingPaneExitIDs.insert(paneID)
    projectPendingPaneExits(&state)
  }

  private static func monotonicMilliseconds() -> Int {
    Int(ProcessInfo.processInfo.systemUptime * 1_000)
  }

  private static func focusedTabID(in workspaceID: String, snapshot: HerdrSessionSnapshot)
    -> String?
  {
    snapshot.workspaces.first { $0.id == workspaceID }?.activeTabID
      ?? snapshot.tabs.first { $0.workspaceID == workspaceID && $0.focused }?.id
  }

  private static func applyFocusEvent(
    _ state: inout State,
    _ event: HerdrEventEnvelope
  ) -> Bool {
    guard let focus = event.focus else { return false }
    switch event.event {
    case "workspace_focused":
      guard let workspaceID = focus.workspaceID else { return false }
      state.selectedWorkspaceID = workspaceID
      state.selectedTabID = Self.focusedTabID(in: workspaceID, snapshot: state.snapshot)
      state.selectedPaneID =
        state.snapshot.panes.first {
          $0.workspaceID == workspaceID && $0.focused
        }?.id
      return true
    case "tab_focused":
      guard let tabID = focus.tabID else { return false }
      state.selectedTabID = tabID
      let tab = state.snapshot.tabs.first { $0.id == tabID }
      state.selectedWorkspaceID = focus.workspaceID ?? tab?.workspaceID
      state.selectedPaneID =
        state.snapshot.panes.first {
          $0.tabID == tabID && $0.focused
        }?.id
      return true
    case "pane_focused":
      guard let paneID = focus.paneID else { return false }
      state.selectedPaneID = paneID
      let pane = state.snapshot.panes.first { $0.id == paneID }
      state.selectedWorkspaceID = focus.workspaceID ?? pane?.workspaceID
      state.selectedTabID = focus.tabID ?? pane?.tabID
      return true
    default:
      return false
    }
  }

  private static func event(_ event: HerdrEventEnvelope, confirms target: FocusTarget) -> Bool {
    guard let focus = event.focus else { return false }
    switch target {
    case .workspace(let id): return focus.workspaceID == id
    case .tab(let id): return focus.tabID == id
    case .pane(let id): return focus.paneID == id
    }
  }

  private static func beginFocus(_ state: inout State, target: FocusTarget) {
    if state.pendingFocus == nil {
      state.focusRollback = FocusSelection(
        workspaceID: state.selectedWorkspaceID,
        tabID: state.selectedTabID,
        paneID: state.selectedPaneID
      )
    }
    state.pendingFocus = target
    applyOptimisticFocus(&state, target: target)
  }

  private static func applyOptimisticFocus(_ state: inout State, target: FocusTarget) {
    switch target {
    case .workspace(let workspaceID):
      state.selectedWorkspaceID = workspaceID
      state.selectedTabID = focusedTabID(in: workspaceID, snapshot: state.snapshot)
      if let tabID = state.selectedTabID {
        state.selectedPaneID =
          state.snapshot.panes.first { $0.tabID == tabID && $0.focused }?.id
          ?? state.snapshot.panes.first { $0.tabID == tabID }?.id
      }
    case .tab(let tabID):
      state.selectedTabID = tabID
      state.selectedWorkspaceID = state.snapshot.tabs.first { $0.id == tabID }?.workspaceID
      state.selectedPaneID =
        state.snapshot.panes.first { $0.tabID == tabID && $0.focused }?.id
        ?? state.snapshot.panes.first { $0.tabID == tabID }?.id
    case .pane(let paneID):
      state.selectedPaneID = paneID
      guard let pane = state.snapshot.panes.first(where: { $0.id == paneID }) else { return }
      state.selectedWorkspaceID = pane.workspaceID
      state.selectedTabID = pane.tabID
    }
  }

  private static func rollbackFocus(_ state: inout State) {
    if let rollback = state.focusRollback {
      state.selectedWorkspaceID = rollback.workspaceID
      state.selectedTabID = rollback.tabID
      state.selectedPaneID = rollback.paneID
    }
    state.pendingFocus = nil
    state.focusRollback = nil
  }

  @Dependency(HerdrTerminalChromeClient.self) private var client
  @Dependency(\.continuousClock) private var clock

  internal var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .foregroundChanged(false), .stop:
        state.connection = .hidden
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        state.pendingFocus = nil
        state.focusRollback = nil
        state.pendingMutation = nil
        state.closeConfirmation = nil
        state.mutationError = nil
        state.subscribedPaneIDs = []
        state.pendingPaneExitIDs = []
        state.subscriptionAwaitingSnapshot = false
        state.refreshGeneration &+= 1
        state.mutationGeneration &+= 1
        return .merge(
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.focusConfirmation),
          .cancel(id: CancelID.mutation)
        )

      case .foregroundChanged(true):
        state.connection = .connecting
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        state.pendingFocus = nil
        state.focusRollback = nil
        state.pendingMutation = nil
        state.closeConfirmation = nil
        state.mutationError = nil
        state.subscribedPaneIDs = []
        state.pendingPaneExitIDs = []
        state.subscriptionAwaitingSnapshot = false
        state.refreshGeneration &+= 1
        state.mutationGeneration &+= 1
        return .merge(
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.focusConfirmation),
          .cancel(id: CancelID.mutation),
          lifecycleEffect()
            .cancellable(id: CancelID.lifecycle, cancelInFlight: true)
        )

      case .snapshotResponse(.success(let snapshot)):
        guard state.connection != .hidden else { return .none }
        let wasAwaitingSnapshot = state.subscriptionAwaitingSnapshot
        let shouldRestartLifecycle = replaceSnapshot(&state, with: snapshot) && wasAwaitingSnapshot
        state.subscriptionAwaitingSnapshot = false
        state.connection = .connected
        return shouldRestartLifecycle ? restartLifecycleEffect() : .none

      case .subscriptionPrepared(let paneIDs):
        guard state.connection != .hidden else { return .none }
        state.subscribedPaneIDs = paneIDs
        state.subscriptionAwaitingSnapshot = true
        return .none

      case .snapshotResponse(.failure(let failure)):
        guard state.connection != .hidden else { return .none }
        return handleFailure(&state, failure: failure)

      case .eventStream(.subscribed):
        return .none

      case .eventStream(.event(let event)):
        guard state.connection == .connected else { return .none }
        let eventName = event.event
        herdrTerminalChromeLogger.diagnostic(
          "event-received uptime_ms=\(Self.monotonicMilliseconds()) name=\(eventName) generation=\(state.refreshGeneration)"
        )
        if eventName.replacing(".", with: "_") == "pane_exited" {
          applyPaneExit(&state, event: event)
        }
        if let pendingFocus = state.pendingFocus,
          Self.focusEvents.contains(eventName.replacing(".", with: "_")),
          !Self.event(event, confirms: pendingFocus)
        {
          return .none
        }
        if Self.applyFocusEvent(&state, event) {
          if state.pendingFocus != nil {
            state.pendingFocus = nil
            state.focusRollback = nil
          }
          let workspace = state.selectedWorkspaceID ?? "?"
          let tab = state.selectedTabID ?? "?"
          let pane = state.selectedPaneID ?? "?"
          herdrTerminalChromeLogger.diagnostic(
            "focus-projected uptime_ms=\(Self.monotonicMilliseconds()) workspace=\(workspace) tab=\(tab) pane=\(pane)"
          )
          return .merge(
            .cancel(id: CancelID.focusConfirmation),
            scheduleDebouncedRefresh(&state, invalidatesInFlightRefresh: true)
          )
        }
        if Self.shouldRefreshImmediately(for: eventName) {
          herdrTerminalChromeLogger.diagnostic(
            "snapshot-scheduled-immediate uptime_ms=\(Self.monotonicMilliseconds())"
          )
          return startRefresh(&state)
        }
        if eventName.replacing(".", with: "_") == "tab_renamed" {
          return scheduleDebouncedRefresh(&state, invalidatesInFlightRefresh: true)
        }
        return scheduleDebouncedRefresh(&state)

      case .eventStream(.disconnected(let error)):
        let failure = HerdrTerminalChromeFailure.map(error)
        if failure.isIncompatibleProtocol {
          return handleFailure(&state, failure: failure)
        }
        state.refreshGeneration &+= 1
        state.mutationGeneration &+= 1
        state.connection = .connecting
        state.snapshot = .empty
        state.pendingMutation = nil
        state.closeConfirmation = nil
        state.subscribedPaneIDs = []
        state.pendingPaneExitIDs = []
        state.subscriptionAwaitingSnapshot = false
        state.pendingFocus = nil
        state.focusRollback = nil
        return .merge(
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.focusConfirmation),
          .cancel(id: CancelID.mutation)
        )

      case .debouncedRefresh:
        guard state.connection == .connected else { return .none }
        return startRefresh(&state)

      case .refreshResponseWithGeneration(let generation, let result):
        guard generation == state.refreshGeneration else { return .none }
        switch result {
        case .success(let snapshot):
          guard state.connection != .hidden else { return .none }
          let shouldRestartLifecycle = replaceSnapshot(&state, with: snapshot)
          let focusedWorkspace = snapshot.focusedWorkspaceID ?? "?"
          let focusedTab = snapshot.focusedTabID ?? "?"
          herdrTerminalChromeLogger.diagnostic(
            "snapshot-applied uptime_ms=\(Self.monotonicMilliseconds()) generation=\(generation) focused_workspace=\(focusedWorkspace) focused_tab=\(focusedTab)"
          )
          state.connection = .connected
          return shouldRestartLifecycle ? restartLifecycleEffect() : .none
        case .failure(let failure):
          guard state.connection != .hidden else { return .none }
          state.pendingFocus = nil
          state.focusRollback = nil
          if failure.isIncompatibleProtocol {
            return handleFailure(&state, failure: failure)
          }
          state.connection = .connecting
          state.snapshot = .empty
          state.pendingMutation = nil
          state.closeConfirmation = nil
          state.subscribedPaneIDs = []
          state.pendingPaneExitIDs = []
          state.subscriptionAwaitingSnapshot = false
          state.mutationGeneration &+= 1
          return .merge(
            .cancel(id: CancelID.mutation),
            restartLifecycleEffect()
          )
        }

      case .focusWorkspaceTapped(let workspaceID):
        guard state.connection == .connected else { return .none }
        let target = FocusTarget.workspace(workspaceID)
        Self.beginFocus(&state, target: target)
        return .merge(
          focusEffect(target).cancellable(id: CancelID.focus, cancelInFlight: true),
          focusConfirmationEffect(target)
        )

      case .focusTabTapped(let tabID):
        guard state.connection == .connected else { return .none }
        let target = FocusTarget.tab(tabID)
        Self.beginFocus(&state, target: target)
        return .merge(
          focusEffect(target).cancellable(id: CancelID.focus, cancelInFlight: true),
          focusConfirmationEffect(target)
        )

      case .focusPaneTapped(let paneID):
        guard state.connection == .connected else { return .none }
        let target = FocusTarget.pane(paneID)
        Self.beginFocus(&state, target: target)
        return .merge(
          focusEffect(target).cancellable(id: CancelID.focus, cancelInFlight: true),
          focusConfirmationEffect(target)
        )

      case .focusResponse(.success):
        return .none

      case .focusResponse(.failure(let failure)):
        Self.rollbackFocus(&state)
        herdrTerminalChromeLogger.warning(
          "Terminal chrome focus failed: \(String(describing: failure))")
        let cancelConfirmation = Effect<Action>.cancel(id: CancelID.focusConfirmation)
        guard failure.isNotFound else { return cancelConfirmation }
        return .merge(
          cancelConfirmation,
          startRefresh(&state)
        )

      case .focusConfirmationTimedOut(let target):
        guard state.pendingFocus == target else { return .none }
        state.pendingFocus = nil
        state.focusRollback = nil
        return startRefresh(&state)

      case .herdrNavigationKeyPressed:
        guard state.connection == .connected else { return .none }
        return scheduleDebouncedRefresh(&state, invalidatesInFlightRefresh: true)

      case .newWorkspaceRequested:
        guard state.connection == .connected else { return .none }
        return startMutation(&state, .createWorkspace)

      case .newTabRequested(let workspaceID, let label, let sourceTabID):
        guard state.connection == .connected else { return .none }
        return startMutation(
          &state,
          .createTab(workspaceID: workspaceID, label: label, sourceTabID: sourceTabID)
        )

      case .renameTabRequested(let tabID, let label):
        guard state.connection == .connected, !label.isEmpty else { return .none }
        return startMutation(&state, .renameTab(tabID: tabID, label: label))

      case .resetTabNameRequested(let tabID):
        guard state.connection == .connected else { return .none }
        return startMutation(&state, .renameTab(tabID: tabID, label: nil))

      case .moveTabRequested(let tabID, let insertIndex):
        guard state.connection == .connected, insertIndex >= 0 else { return .none }
        return startMutation(
          &state,
          .moveTab(tabID: tabID, insertIndex: insertIndex)
        )

      case .closeTabRequested(let tabID, let workspaceID):
        guard state.connection == .connected else { return .none }
        let isLastTab = state.snapshot.tabs.filter { $0.workspaceID == workspaceID }.count <= 1
        return startMutation(
          &state,
          .closeTab(
            tabID: tabID,
            workspaceID: workspaceID,
            isLastTab: isLastTab
          )
        )

      case .closeConfirmationConfirmed:
        guard let confirmation = state.closeConfirmation else { return .none }
        state.closeConfirmation = nil
        return startMutation(
          &state,
          .closeWorkspace(workspaceID: confirmation.workspaceID)
        )

      case .closeConfirmationCancelled:
        state.closeConfirmation = nil
        state.pendingMutation = nil
        return .none

      case .mutationErrorDismissed:
        state.mutationError = nil
        return .none

      case .mutationResponse(let generation, let result):
        guard generation == state.mutationGeneration else { return .none }
        let pendingMutation = state.pendingMutation
        state.pendingMutation = nil
        switch result {
        case .success:
          state.mutationError = nil
          if case .some(.renameTab) = pendingMutation {
            state.refreshGeneration &+= 1
            return .merge(
              .cancel(id: CancelID.refresh),
              scheduleDebouncedRefresh(&state)
            )
          }
          return startRefresh(&state)
        case .failure(let failure):
          if case .closeTab(_, let workspaceID, true) = pendingMutation,
            failure.isConfirmationRequired
          {
            state.closeConfirmation = CloseConfirmation(workspaceID: workspaceID)
            state.mutationError = nil
            return .none
          }
          state.mutationError = failure
          if failure.isNotFound {
            return startRefresh(&state)
          }
          return .none
        }

      case .delegate:
        return .none
      }
    }
  }

  private func startMutation(
    _ state: inout State,
    _ mutation: Mutation
  ) -> Effect<Action> {
    state.pendingMutation = mutation
    state.mutationError = nil
    state.mutationGeneration &+= 1
    let generation = state.mutationGeneration
    let client = client
    return .run { send in
      do {
        switch mutation {
        case .createWorkspace:
          try await client.createWorkspace()
        case .createTab(let workspaceID, let label, let sourceTabID):
          try await client.createTab(workspaceID, label, sourceTabID)
        case .renameTab(let tabID, let label):
          try await client.renameTab(tabID, label)
        case .moveTab(let tabID, let insertIndex):
          try await client.moveTab(tabID, insertIndex)
        case .closeTab(let tabID, _, _):
          try await client.closeTab(tabID)
        case .closeWorkspace(let workspaceID):
          try await client.closeWorkspace(workspaceID)
        }
        guard !Task.isCancelled else { return }
        await send(.mutationResponse(generation, .success))
      } catch {
        guard !Task.isCancelled else { return }
        await send(
          .mutationResponse(generation, .failure(HerdrTerminalChromeFailure.map(error)))
        )
      }
    }
    .cancellable(id: CancelID.mutation, cancelInFlight: true)
  }

  private func startRefresh(_ state: inout State) -> Effect<Action> {
    state.refreshGeneration &+= 1
    return refreshEffect(generation: state.refreshGeneration)
      .cancellable(id: CancelID.refresh, cancelInFlight: true)
  }

  private func scheduleDebouncedRefresh(
    _ state: inout State,
    invalidatesInFlightRefresh: Bool = false
  ) -> Effect<Action> {
    if invalidatesInFlightRefresh {
      state.refreshGeneration &+= 1
    }
    let delay = Effect<Action>.run { [clock] send in
      do {
        try await clock.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        await send(.debouncedRefresh)
      } catch {
        return
      }
    }
    .cancellable(id: CancelID.refreshDebounce, cancelInFlight: true)
    return invalidatesInFlightRefresh
      ? .merge(.cancel(id: CancelID.refresh), delay)
      : delay
  }

  private func lifecycleEffect() -> Effect<Action> {
    let client = client
    let clock = clock
    return .run { send in
      var retryDelay = Duration.milliseconds(250)
      while !Task.isCancelled {
        do {
          let discoverySnapshot = try await client.snapshot()
          let subscription = try await client.subscribeEvents(Set(discoverySnapshot.panes.map(\.id)))
          defer { subscription.cancel() }
          guard !Task.isCancelled else { return }
          await send(.subscriptionPrepared(Set(discoverySnapshot.panes.map(\.id))))
          guard !Task.isCancelled else { return }
          let snapshot = try await client.snapshot()
          guard !Task.isCancelled else { return }
          await send(.snapshotResponse(.success(snapshot)))
          retryDelay = .milliseconds(250)

          for await event in subscription.stream {
            guard !Task.isCancelled else { return }
            await send(.eventStream(event))
            if case .disconnected = event {
              break
            }
          }
        } catch {
          let failure = HerdrTerminalChromeFailure.map(error)
          guard !Task.isCancelled else { return }
          await send(.snapshotResponse(.failure(failure)))
          if failure.isIncompatibleProtocol {
            return
          }
        }

        do {
          try await clock.sleep(for: retryDelay)
        } catch {
          return
        }
        retryDelay = min(retryDelay * 2, .seconds(2))
      }
    }
  }

  private func refreshEffect(generation: UInt64) -> Effect<Action> {
    let client = client
    return .run { send in
      let startedAt = ProcessInfo.processInfo.systemUptime
      herdrTerminalChromeLogger.diagnostic(
        "snapshot-effect-start uptime_ms=\(Int(startedAt * 1_000)) generation=\(generation)"
      )
      do {
        let snapshot = try await client.snapshot()
        guard !Task.isCancelled else { return }
        herdrTerminalChromeLogger.diagnostic(
          "snapshot-effect-end uptime_ms=\(Int(ProcessInfo.processInfo.systemUptime * 1_000)) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)) generation=\(generation)"
        )
        await send(.refreshResponseWithGeneration(generation, .success(snapshot)))
      } catch {
        guard !Task.isCancelled else { return }
        herdrTerminalChromeLogger.diagnostic(
          "snapshot-effect-failure uptime_ms=\(Int(ProcessInfo.processInfo.systemUptime * 1_000)) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)) generation=\(generation) error=\(String(describing: error))"
        )
        await send(
          .refreshResponseWithGeneration(
            generation,
            .failure(HerdrTerminalChromeFailure.map(error))
          )
        )
      }
    }
  }

  private func focusEffect(_ target: FocusTarget) -> Effect<Action> {
    let client = client
    return .run { send in
      do {
        switch target {
        case .workspace(let id):
          try await client.focusWorkspace(id)
        case .tab(let id):
          try await client.focusTab(id)
        case .pane(let id):
          try await client.focusPane(id)
        }
        guard !Task.isCancelled else { return }
        await send(.focusResponse(.success))
      } catch {
        guard !Task.isCancelled else { return }
        await send(.focusResponse(.failure(HerdrTerminalChromeFailure.map(error))))
      }
    }
  }

  private func focusConfirmationEffect(_ target: FocusTarget) -> Effect<Action> {
    .run { [clock] send in
      do {
        try await clock.sleep(for: Self.focusConfirmationTimeout)
      } catch {
        return
      }
      await send(.focusConfirmationTimedOut(target))
    }
    .cancellable(id: CancelID.focusConfirmation, cancelInFlight: true)
  }

  private func handleFailure(
    _ state: inout State,
    failure: HerdrTerminalChromeFailure
  ) -> Effect<Action> {
    if case .incompatibleProtocol(let error) = failure {
      state.connection = .hidden
      state.snapshot = .empty
      state.pendingPaneExitIDs = []
      state.selectedWorkspaceID = nil
      state.selectedTabID = nil
      state.selectedPaneID = nil
      state.pendingFocus = nil
      state.focusRollback = nil
      state.pendingMutation = nil
      state.closeConfirmation = nil
      state.mutationError = nil
      state.mutationGeneration &+= 1
      return .merge(
        .cancel(id: CancelID.lifecycle),
        .cancel(id: CancelID.refreshDebounce),
        .cancel(id: CancelID.refresh),
        .cancel(id: CancelID.focus),
        .cancel(id: CancelID.focusConfirmation),
        .cancel(id: CancelID.mutation),
        .send(.delegate(.compatibilityFailure(error)))
      )
    }
    state.connection = .failed
    state.snapshot = .empty
    state.pendingPaneExitIDs = []
    state.selectedWorkspaceID = nil
    state.selectedTabID = nil
    state.selectedPaneID = nil
    state.pendingFocus = nil
    state.focusRollback = nil
    state.pendingMutation = nil
    state.closeConfirmation = nil
    state.mutationGeneration &+= 1
    herdrTerminalChromeLogger.debug("Terminal chrome unavailable: \(String(describing: failure))")
    return .none
  }

  private func replaceSnapshot(_ state: inout State, with snapshot: HerdrSessionSnapshot) -> Bool {
    let snapshotPaneIDs = Set(snapshot.panes.map(\.id))
    state.pendingPaneExitIDs.formIntersection(snapshotPaneIDs)
    let projectedSnapshot = Self.snapshotByRemovingPanes(
      snapshot,
      paneIDs: state.pendingPaneExitIDs
    )
    let paneIDs = Set(projectedSnapshot.panes.map(\.id))
    let shouldRestartLifecycle = Self.paneSetRequiresLifecycleRestart(
      subscribedPaneIDs: state.subscribedPaneIDs,
      snapshotPaneIDs: paneIDs
    )
    state.snapshot = projectedSnapshot
    state.subscribedPaneIDs = paneIDs
    state.selectedWorkspaceID = reconciledSelection(
      serverFocused: projectedSnapshot.focusedWorkspaceID,
      validIDs: Set(projectedSnapshot.workspaces.map(\.id))
    )
    state.selectedTabID = reconciledSelection(
      serverFocused: projectedSnapshot.focusedTabID,
      validIDs: Set(projectedSnapshot.tabs.map(\.id))
    )
    state.selectedPaneID = reconciledSelection(
      serverFocused: projectedSnapshot.focusedPaneID,
      validIDs: Set(projectedSnapshot.panes.map(\.id))
    )

    guard let pendingFocus = state.pendingFocus else {
      state.focusRollback = nil
      return shouldRestartLifecycle
    }
    let isConfirmed: Bool
    switch pendingFocus {
    case .workspace(let id):
      isConfirmed = projectedSnapshot.focusedWorkspaceID == id
    case .tab(let id):
      isConfirmed = projectedSnapshot.focusedTabID == id
    case .pane(let id):
      isConfirmed = projectedSnapshot.focusedPaneID == id
    }
    let targetStillExists: Bool
    switch pendingFocus {
    case .workspace(let id):
      targetStillExists = projectedSnapshot.workspaces.contains { $0.id == id }
    case .tab(let id):
      targetStillExists = projectedSnapshot.tabs.contains { $0.id == id }
    case .pane(let id):
      targetStillExists = projectedSnapshot.panes.contains { $0.id == id }
    }
    guard targetStillExists else {
      state.pendingFocus = nil
      state.focusRollback = nil
      return shouldRestartLifecycle
    }
    guard isConfirmed else {
      Self.applyOptimisticFocus(&state, target: pendingFocus)
      return shouldRestartLifecycle
    }
    switch pendingFocus {
    case .workspace(let id):
      state.selectedWorkspaceID = id
    case .tab(let id):
      state.selectedTabID = id
    case .pane(let id):
      state.selectedPaneID = id
    }
    state.pendingFocus = nil
    state.focusRollback = nil
    return shouldRestartLifecycle
  }

  private func reconciledSelection(
    serverFocused: String?,
    validIDs: Set<String>
  ) -> String? {
    guard let serverFocused, validIDs.contains(serverFocused) else { return nil }
    return serverFocused
  }

  private func restartLifecycleEffect() -> Effect<Action> {
    .merge(
      .cancel(id: CancelID.lifecycle),
      lifecycleEffect().cancellable(id: CancelID.lifecycle, cancelInFlight: true)
    )
  }
}
