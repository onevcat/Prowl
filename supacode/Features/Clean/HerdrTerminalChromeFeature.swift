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
      case unavailable
      case incompatible
      case failed
    }

    internal enum AuthorityMode: Equatable {
      case bootstrap
      case probing
      case aggregate
      case incompatible
      case legacy
    }

    internal var authorityMode: AuthorityMode = .bootstrap
    internal var isForeground = false
    internal var connection: Connection = .hidden
    internal var aggregateState: HerdrAggregateState?
    internal var aggregateSyncCommitted = false
    internal var nativeClientInstanceID: String?
    internal var nativeEventSequence: UInt64?
    internal var nativeProjectionRevision: UInt64?
    internal var nativeConnectionEpoch: UInt64 = 0
    internal var endpointWatermarks = HerdrEndpointWatermarks()
    internal var isResyncPending = false
    internal var nativeRequestSequence: UInt64 = 0
    internal var activationEpoch: UInt64 = 0
    internal var aggregateProcessInfoByPaneTarget: [HerdrPaneTarget: HerdrPaneProcessInfo] = [:]
    internal var pendingNativeMutationRequestID: String?
    internal var pendingNativeMutationFence: HerdrEndpointFence?
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
      guard isForeground else { return false }
      switch authorityMode {
      case .aggregate, .incompatible: return connection != .hidden
      case .legacy: return connection == .connected
      case .bootstrap, .probing: return false
      }
    }

    internal var committedActiveEndpointKey: HerdrEndpointKey? {
      authorityMode == .legacy ? .local : aggregateState?.committedActiveEndpointKey
    }

    internal var acceptsLegacyAuthority: Bool {
      authorityMode == .legacy
    }

    internal var endpointProjections: [HerdrEndpointProjection] {
      aggregateState?.endpoints ?? []
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
    case nativeEvent(HerdrNativeClientEvent)
    case nativeHandshakeTimedOut(clientInstanceID: String)
    case foregroundChanged(Bool)
    case subscriptionPrepared(Set<String>)
    case snapshotResponse(Result<HerdrSessionSnapshot, HerdrTerminalChromeFailure>)
    case eventStream(HerdrEventStreamState)
    case debouncedRefresh
    case refreshResponseWithGeneration(
      UInt64,
      Result<HerdrSessionSnapshot, HerdrTerminalChromeFailure>
    )
    case focusWorkspaceTarget(HerdrWorkspaceTarget)
    case focusTabTarget(HerdrTabTarget)
    case focusPaneTarget(HerdrPaneTarget)
    case focusWorkspaceTapped(String)
    case focusTabTapped(String)
    case focusPaneTapped(String)
    case focusResponse(FocusResult)
    case focusConfirmationTimedOut(FocusTarget)
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
    case nativeProcessInfoPoll
    case delegate(DelegateAction)
    case stop
  }

  nonisolated private enum CancelID: Hashable, Sendable {
    case nativeLifecycle
    case nativeHandshake
    case lifecycle
    case refreshDebounce
    case refresh
    case focus
    case focusConfirmation
    case mutation
    case processInfoPoll
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
  private static let nativeClaimHandshakeTimeout = Duration.seconds(1)
  private static let nativeMutationTimeout = Duration.seconds(5)

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
      guard tabIDs.contains(layout.tabID), workspaceIDs.contains(layout.workspaceID) else {
        return nil
      }
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

  private static func focusedPaneID(in tabID: String, snapshot: HerdrSessionSnapshot) -> String? {
    snapshot.layouts.first { $0.tabID == tabID }?.focusedPaneID
      ?? snapshot.layouts.first(where: { $0.tabID == tabID })?.panes.first(where: \.focused)?.paneID
      ?? snapshot.panes.first { $0.tabID == tabID && $0.focused }?.id
      ?? snapshot.panes.first { $0.tabID == tabID }?.id
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
      case .foregroundChanged(false):
        state.isForeground = false
        state.connection = .hidden
        state.pendingFocus = nil
        state.focusRollback = nil
        state.pendingMutation = nil
        state.pendingNativeMutationRequestID = nil
        state.pendingNativeMutationFence = nil
        state.closeConfirmation = nil
        state.mutationError = nil
        state.refreshGeneration &+= 1
        state.mutationGeneration &+= 1
        if state.authorityMode == .aggregate {
          return .merge(
            .cancel(id: CancelID.focus),
            .cancel(id: CancelID.focusConfirmation),
            .cancel(id: CancelID.mutation),
            .cancel(id: CancelID.processInfoPoll)
          )
        }
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        state.subscribedPaneIDs = []
        state.pendingPaneExitIDs = []
        state.subscriptionAwaitingSnapshot = false
        return .merge(
          .cancel(id: CancelID.nativeLifecycle),
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.focusConfirmation),
          .cancel(id: CancelID.mutation),
          .cancel(id: CancelID.processInfoPoll)
        )

      case .stop:
        state.isForeground = false
        state.authorityMode = .bootstrap
        state.connection = .hidden
        state.aggregateState = nil
        state.aggregateSyncCommitted = false
        state.nativeClientInstanceID = nil
        state.nativeEventSequence = nil
        state.nativeProjectionRevision = nil
        state.nativeConnectionEpoch = 0
        state.endpointWatermarks = HerdrEndpointWatermarks()
        state.isResyncPending = false
        state.nativeRequestSequence = 0
        state.activationEpoch = 0
        state.aggregateProcessInfoByPaneTarget = [:]
        state.pendingNativeMutationRequestID = nil
        state.pendingNativeMutationFence = nil
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
          .cancel(id: CancelID.nativeLifecycle),
          .cancel(id: CancelID.nativeHandshake),
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.focusConfirmation),
          .cancel(id: CancelID.mutation)
        )

      case .foregroundChanged(true):
        state.isForeground = true
        if state.authorityMode == .aggregate {
          if state.aggregateSyncCommitted,
            let endpoint = state.aggregateState?.committedEndpoint,
            endpoint.status == .online,
            endpoint.freshness == .current
          {
            state.connection = .connected
            if let snapshot = endpoint.snapshot {
              return nativeProcessInfoEffect(&state, endpoint: endpoint, snapshot: snapshot)
            }
          } else {
            state.connection = .unavailable
          }
          return .none
        }
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
        switch state.authorityMode {
        case .bootstrap:
          state.authorityMode = .probing
          return nativeLifecycleEffect()
            .cancellable(id: CancelID.nativeLifecycle, cancelInFlight: true)
        case .probing:
          return nativeLifecycleEffect()
            .cancellable(id: CancelID.nativeLifecycle, cancelInFlight: true)
        case .aggregate:
          return .none
        case .legacy:
          return lifecycleEffect()
            .cancellable(id: CancelID.lifecycle, cancelInFlight: true)
        case .incompatible:
          state.connection = .incompatible
          return .none
        }

      case .nativeEvent(.noContractClaim):
        guard state.authorityMode == .probing else { return .none }
        state.authorityMode = .legacy
        state.connection = state.isForeground ? .connecting : .hidden
        guard state.isForeground else { return .none }
        return lifecycleEffect()
          .cancellable(id: CancelID.lifecycle, cancelInFlight: true)

      case .nativeEvent(.aggregateStarted(let clientInstanceID)):
        guard state.authorityMode != .legacy, state.authorityMode != .incompatible else {
          return .none
        }
        state.authorityMode = .aggregate
        state.nativeClientInstanceID = clientInstanceID
        state.connection = .connecting
        state.isResyncPending = false
        return .merge(
          .cancel(id: CancelID.lifecycle),
          nativeHandshakeTimeoutEffect(clientInstanceID: clientInstanceID)
        )

      case .nativeHandshakeTimedOut(let clientInstanceID):
        guard state.authorityMode == .aggregate,
          !state.aggregateSyncCommitted,
          state.nativeClientInstanceID == clientInstanceID
        else { return .none }
        return .send(
          .nativeEvent(.incompatible("Aggregate sync did not commit within one second."))
        )

      case .nativeEvent(.incompatible(let message)),
        .nativeEvent(.stream(.incompatible(let message))):
        guard state.authorityMode != .legacy else { return .none }
        state.authorityMode = .incompatible
        state.connection = .incompatible
        state.aggregateSyncCommitted = false
        state.aggregateProcessInfoByPaneTarget = [:]
        invalidatePendingMutation(&state, incrementGeneration: true)
        state.closeConfirmation = nil
        state.mutationError = nil
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        herdrTerminalChromeLogger.warning("Native chrome contract incompatible: \(message)")
        return .merge(
          .cancel(id: CancelID.nativeHandshake),
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.mutation),
          .cancel(id: CancelID.processInfoPoll)
        )

      case .nativeEvent(.stream(.reconnected(let epoch))):
        guard state.authorityMode == .aggregate else { return .none }
        state.connection = .connecting
        state.aggregateSyncCommitted = false
        state.isResyncPending = false
        state.nativeEventSequence = nil
        state.nativeProjectionRevision = nil
        state.aggregateProcessInfoByPaneTarget = [:]
        invalidatePendingMutation(&state, incrementGeneration: true)
        state.pendingFocus = nil
        state.focusRollback = nil
        state.snapshot = .empty
        state.nativeConnectionEpoch = epoch
        return .merge(
          .cancel(id: CancelID.mutation),
          nativeResyncEffect(&state),
          nativeHandshakeTimeoutEffect(clientInstanceID: state.nativeClientInstanceID ?? "")
        )

      case .nativeEvent(.stream(.disconnected)):
        guard state.authorityMode == .aggregate else { return .none }
        state.connection = state.isForeground ? .unavailable : .hidden
        state.aggregateSyncCommitted = false
        state.aggregateProcessInfoByPaneTarget = [:]
        invalidatePendingMutation(&state, incrementGeneration: true)
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        state.pendingFocus = nil
        return .merge(
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.mutation)
        )

      case .nativeEvent(.stream(.frame(let frame))):
        guard state.authorityMode == .aggregate else { return .none }
        let frameEffect = applyNativeFrame(&state, frame: frame)
        guard state.aggregateSyncCommitted else { return frameEffect }
        return .merge(.cancel(id: CancelID.nativeHandshake), frameEffect)

      case .nativeProcessInfoPoll:
        guard state.authorityMode == .aggregate,
          state.aggregateSyncCommitted,
          let endpoint = state.aggregateState?.committedEndpoint,
          let snapshot = endpoint.snapshot
        else { return .none }
        return nativeProcessInfoEffect(&state, endpoint: endpoint, snapshot: snapshot)

      case .snapshotResponse(.success(let snapshot)):
        guard state.acceptsLegacyAuthority, state.connection != .hidden else { return .none }
        let wasAwaitingSnapshot = state.subscriptionAwaitingSnapshot
        let shouldRestartLifecycle = replaceSnapshot(&state, with: snapshot) && wasAwaitingSnapshot
        state.subscriptionAwaitingSnapshot = false
        state.connection = .connected
        return shouldRestartLifecycle ? restartLifecycleEffect() : .none

      case .subscriptionPrepared(let paneIDs):
        guard state.acceptsLegacyAuthority, state.connection != .hidden else { return .none }
        state.subscribedPaneIDs = paneIDs
        state.subscriptionAwaitingSnapshot = true
        return .none

      case .snapshotResponse(.failure(let failure)):
        guard state.acceptsLegacyAuthority, state.connection != .hidden else { return .none }
        return handleFailure(&state, failure: failure)

      case .eventStream(.subscribed):
        guard state.acceptsLegacyAuthority else { return .none }
        return .none

      case .eventStream(.event(let event)):
        guard state.acceptsLegacyAuthority, state.connection == .connected else { return .none }
        let eventName = event.event
        let uptime = Self.monotonicMilliseconds()
        herdrTerminalChromeLogger.diagnostic(
          "event-received uptime_ms=\(uptime) name=\(eventName) generation=\(state.refreshGeneration)"
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
        guard state.acceptsLegacyAuthority else { return .none }
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
        guard state.acceptsLegacyAuthority, state.connection == .connected else { return .none }
        return startRefresh(&state)

      case .refreshResponseWithGeneration(let generation, let result):
        guard state.acceptsLegacyAuthority, generation == state.refreshGeneration else {
          return .none
        }
        switch result {
        case .success(let snapshot):
          guard state.connection != .hidden else { return .none }
          let shouldRestartLifecycle = replaceSnapshot(&state, with: snapshot)
          let focusedWorkspace = snapshot.focusedWorkspaceID ?? "?"
          let focusedTab = snapshot.focusedTabID ?? "?"
          let uptime = Self.monotonicMilliseconds()
          herdrTerminalChromeLogger.diagnostic(
            "snapshot-applied uptime_ms=\(uptime) generation=\(generation) "
              + "focused_workspace=\(focusedWorkspace) focused_tab=\(focusedTab)"
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

      case .focusWorkspaceTarget(let target):
        guard state.authorityMode == .aggregate, state.connection == .connected else {
          return .none
        }
        return startNativeFocus(
          &state,
          endpointKey: target.endpointKey,
          resourceKind: "workspace",
          resourceID: target.workspaceID
        )

      case .focusTabTarget(let target):
        guard state.authorityMode == .aggregate, state.connection == .connected else {
          return .none
        }
        return startNativeFocus(
          &state,
          endpointKey: target.endpointKey,
          resourceKind: "tab",
          resourceID: target.tabID
        )

      case .focusPaneTarget(let target):
        guard state.authorityMode == .aggregate, state.connection == .connected else {
          return .none
        }
        return startNativeFocus(
          &state,
          endpointKey: target.endpointKey,
          resourceKind: "pane",
          resourceID: target.paneID
        )

      case .focusWorkspaceTapped(let workspaceID):
        guard state.acceptsLegacyAuthority, state.connection == .connected else { return .none }
        let target = FocusTarget.workspace(workspaceID)
        Self.beginFocus(&state, target: target)
        return .merge(
          focusEffect(target).cancellable(id: CancelID.focus, cancelInFlight: true),
          focusConfirmationEffect(target)
        )

      case .focusTabTapped(let tabID):
        guard state.acceptsLegacyAuthority, state.connection == .connected else { return .none }
        let target = FocusTarget.tab(tabID)
        Self.beginFocus(&state, target: target)
        return .merge(
          focusEffect(target).cancellable(id: CancelID.focus, cancelInFlight: true),
          focusConfirmationEffect(target)
        )

      case .focusPaneTapped(let paneID):
        guard state.acceptsLegacyAuthority, state.connection == .connected else { return .none }
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
        guard generation == state.mutationGeneration,
          let pendingMutation = state.pendingMutation,
          state.authorityMode != .aggregate
            || (state.pendingNativeMutationRequestID != nil
              && state.pendingNativeMutationFence != nil)
        else { return .none }
        state.pendingMutation = nil
        state.pendingNativeMutationRequestID = nil
        state.pendingNativeMutationFence = nil
        let followUp: Effect<Action>
        switch result {
        case .success:
          state.mutationError = nil
          if state.authorityMode == .aggregate {
            followUp = .none
          } else if case .renameTab = pendingMutation {
            state.refreshGeneration &+= 1
            followUp = .merge(
              .cancel(id: CancelID.refresh),
              scheduleDebouncedRefresh(&state)
            )
          } else {
            followUp = startRefresh(&state)
          }
        case .failure(let failure):
          if case .closeTab(_, let workspaceID, true) = pendingMutation,
            failure.isConfirmationRequired
          {
            state.closeConfirmation = CloseConfirmation(workspaceID: workspaceID)
            state.mutationError = nil
            followUp = .none
          } else {
            state.mutationError = failure
            followUp = failure.isNotFound ? startRefresh(&state) : .none
          }
        }
        return .merge(.cancel(id: CancelID.mutation), followUp)

      case .delegate:
        return .none
      }
    }
  }

  private func nativeHandshakeTimeoutEffect(clientInstanceID: String) -> Effect<Action> {
    .run { send in
      try await clock.sleep(for: Self.nativeClaimHandshakeTimeout)
      await send(.nativeHandshakeTimedOut(clientInstanceID: clientInstanceID))
    }
    .cancellable(id: CancelID.nativeHandshake, cancelInFlight: true)
  }

  private func nativeLifecycleEffect() -> Effect<Action> {
    let client = client
    return .run { send in
      for await event in client.nativeEvents() {
        guard !Task.isCancelled else { return }
        await send(.nativeEvent(event))
      }
    }
  }

  private func invalidatePendingMutation(_ state: inout State, incrementGeneration: Bool) {
    state.pendingNativeMutationRequestID = nil
    state.pendingNativeMutationFence = nil
    state.pendingMutation = nil
    if incrementGeneration {
      state.mutationGeneration &+= 1
    }
  }

  internal func applyNativeFrame(
    _ state: inout State,
    frame: HerdrNativeAggregateFrame
  ) -> Effect<Action> {
    let explicitlyCommitsSync =
      frame.messageKind == "aggregate_sync_commit" && frame.syncCommitted
    if state.isResyncPending {
      guard explicitlyCommitsSync else { return .none }
      state.nativeEventSequence = nil
      state.nativeProjectionRevision = nil
    } else if let sequence = state.nativeEventSequence {
      guard frame.sequence > sequence else { return .none }
      guard frame.sequence == sequence + 1 else {
        state.aggregateSyncCommitted = false
        state.isResyncPending = true
        state.connection = state.isForeground ? .unavailable : .hidden
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        invalidatePendingMutation(&state, incrementGeneration: true)
        state.closeConfirmation = nil
        state.mutationError = nil
        return .merge(
          .cancel(id: CancelID.mutation),
          nativeResyncEffect(&state)
        )
      }
    }
    if let revision = state.nativeProjectionRevision,
      frame.projectionRevision < revision
    {
      return .none
    }

    let (acceptedEndpoints, replacedEndpointKeys) = acceptedNativeEndpoints(
      &state,
      candidates: frame.state.endpoints
    )
    let replacedMutation = !replacedEndpointKeys.isEmpty
    if replacedMutation {
      state.aggregateProcessInfoByPaneTarget = state.aggregateProcessInfoByPaneTarget.filter {
        !replacedEndpointKeys.contains($0.key.endpointKey)
      }
      invalidatePendingMutation(&state, incrementGeneration: true)
      state.pendingFocus = nil
      state.focusRollback = nil
    }

    let acceptedKeys = Set(acceptedEndpoints.map(\.endpointKey))
    let aggregate = HerdrAggregateState(
      catalogRevision: frame.state.catalogRevision,
      endpoints: acceptedEndpoints,
      perEndpointFocus: frame.state.perEndpointFocus.filter { acceptedKeys.contains($0.key) },
      committedPresentation: frame.state.committedPresentation,
      requestedSelection: frame.state.requestedSelection,
      pendingActivation: frame.state.pendingActivation,
      capabilities: frame.state.capabilities
    )
    state.aggregateState = aggregate
    state.nativeEventSequence = frame.sequence
    state.nativeProjectionRevision = frame.projectionRevision
    if let activationEpoch = frame.activationEpoch {
      state.activationEpoch = max(state.activationEpoch, activationEpoch)
    }
    state.aggregateSyncCommitted = state.aggregateSyncCommitted || explicitlyCommitsSync
    state.isResyncPending = false
    let resultEffect: Effect<Action>
    if state.aggregateSyncCommitted {
      synchronizeNativeProcessInfo(
        &state,
        frame: frame,
        acceptedEndpoints: acceptedEndpoints
      )
      resultEffect = .merge(
        replacedMutation ? .cancel(id: CancelID.mutation) : .none,
        nativeMutationResultEffect(state, frame: frame)
      )
    } else {
      state.aggregateProcessInfoByPaneTarget = [:]
      resultEffect = replacedMutation ? .cancel(id: CancelID.mutation) : .none
    }

    guard state.aggregateSyncCommitted,
      let endpoint = aggregate.committedEndpoint,
      endpoint.status == .online,
      endpoint.freshness == .current,
      let snapshot = endpoint.snapshot
    else {
      state.connection = state.isForeground ? .unavailable : .hidden
      state.snapshot = .empty
      state.selectedWorkspaceID = nil
      state.selectedTabID = nil
      state.selectedPaneID = nil
      return resultEffect
    }
    state.connection = state.isForeground ? .connected : .hidden
    state.snapshot = snapshot.legacyProjection
    let selection = aggregate.committedActiveSelection
    state.selectedWorkspaceID = selection?.workspaceID ?? snapshot.focusedWorkspaceID
    state.selectedTabID = selection?.tabID ?? snapshot.focusedTabID
    state.selectedPaneID = selection?.paneID ?? snapshot.focusedPaneID
    state.pendingFocus = nil
    state.focusRollback = nil
    let processInfoEffect =
      frame.messageKind == "process_info_result"
      ? scheduleNativeProcessInfoPoll()
      : nativeProcessInfoEffect(&state, endpoint: endpoint, snapshot: snapshot)
    return .merge(resultEffect, processInfoEffect)
  }

  private func acceptedNativeEndpoints(
    _ state: inout State,
    candidates: [HerdrEndpointProjection]
  ) -> ([HerdrEndpointProjection], Set<HerdrEndpointKey>) {
    let previousByKey = Dictionary(
      uniqueKeysWithValues: (state.aggregateState?.endpoints ?? []).map { ($0.endpointKey, $0) }
    )
    var accepted: [HerdrEndpointProjection] = []
    var replacedEndpointKeys: Set<HerdrEndpointKey> = []
    for endpoint in candidates {
      switch endpoint.connectionIdentity {
      case .absent:
        accepted.append(endpoint)
      case .concrete(let identity):
        guard let snapshot = endpoint.snapshot,
          snapshot.bootID == identity.serverBootID
        else {
          if let previous = previousByKey[endpoint.endpointKey] {
            accepted.append(previous)
          }
          continue
        }
        let fence = HerdrEndpointFence(
          endpointKey: endpoint.endpointKey,
          identity: identity,
          snapshotRevision: snapshot.revision
        )
        switch state.endpointWatermarks.accept(fence) {
        case .accepted:
          accepted.append(endpoint)
        case .replacedConnection:
          replacedEndpointKeys.insert(endpoint.endpointKey)
          accepted.append(endpoint)
        case .stale:
          if let previous = previousByKey[endpoint.endpointKey],
            previous.connectionIdentity == endpoint.connectionIdentity,
            previous.snapshot?.revision == endpoint.snapshot?.revision
          {
            accepted.append(endpoint)
          } else if let previous = previousByKey[endpoint.endpointKey] {
            accepted.append(previous)
          }
        case .retiredConnection:
          if let previous = previousByKey[endpoint.endpointKey] {
            accepted.append(previous)
          }
        }
      }
    }
    return (accepted, replacedEndpointKeys)
  }

  private func synchronizeNativeProcessInfo(
    _ state: inout State,
    frame: HerdrNativeAggregateFrame,
    acceptedEndpoints: [HerdrEndpointProjection]
  ) {
    if frame.messageKind == "process_info_result",
      let target = frame.processInfoTarget,
      let resultFence = frame.processInfoFence,
      let processInfo = frame.processInfo,
      let endpoint = acceptedEndpoints.first(where: { $0.endpointKey == target.endpointKey }),
      case .concrete(let identity) = endpoint.connectionIdentity,
      let endpointSnapshot = endpoint.snapshot,
      resultFence
        == HerdrEndpointFence(
          endpointKey: target.endpointKey,
          identity: identity,
          snapshotRevision: endpointSnapshot.revision
        )
    {
      state.aggregateProcessInfoByPaneTarget[target] = processInfo
    }
    let validPaneTargets = Set(
      acceptedEndpoints.flatMap { endpoint in
        (endpoint.snapshot?.panes ?? []).map {
          HerdrPaneTarget(endpointKey: endpoint.endpointKey, paneID: $0.paneID)
        }
      }
    )
    state.aggregateProcessInfoByPaneTarget = state.aggregateProcessInfoByPaneTarget.filter {
      validPaneTargets.contains($0.key)
    }
  }

  private func nativeMutationResultEffect(
    _ state: State,
    frame: HerdrNativeAggregateFrame
  ) -> Effect<Action> {
    guard frame.messageKind == "mutation_result",
      frame.requestID == state.pendingNativeMutationRequestID,
      let pendingFence = state.pendingNativeMutationFence,
      let result = frame.mutationResult,
      result.endpointKey == pendingFence.endpointKey,
      result.endpointFence == pendingFence
    else { return .none }
    let response: MutationResult =
      result.succeeded
      ? .success
      : .failure(.invalidResponse(result.message ?? "Herdr rejected the mutation."))
    return .send(.mutationResponse(state.mutationGeneration, response))
  }

  private func nativeProcessInfoEffect(
    _ state: inout State,
    endpoint: HerdrEndpointProjection,
    snapshot: HerdrClientShellSnapshot
  ) -> Effect<Action> {
    guard case .concrete(let identity) = endpoint.connectionIdentity else { return .none }
    let fence = HerdrEndpointFence(
      endpointKey: endpoint.endpointKey,
      identity: identity,
      snapshotRevision: snapshot.revision
    )
    let paneIDs = Dictionary(grouping: snapshot.panes, by: \.tabID).values.compactMap { panes in
      (panes.first(where: \.focused) ?? panes.first)?.paneID
    }
    let client = client
    let effects = paneIDs.map { paneID in
      state.nativeRequestSequence &+= 1
      let request = HerdrNativeActionRequest(
        requestID: "prowl-native-process-\(state.nativeRequestSequence)",
        activationEpoch: nil,
        payload: HerdrNativeActionPayload(
          action: "process_info",
          endpointKey: endpoint.endpointKey,
          endpointFence: fence,
          resourceKind: "pane",
          resourceID: paneID,
          method: nil,
          params: nil
        )
      )
      return Effect<Action>.run { _ in try await client.sendNativeAction(request) }
    }
    return .merge(.merge(effects), scheduleNativeProcessInfoPoll())
  }

  private func scheduleNativeProcessInfoPoll() -> Effect<Action> {
    .run { send in
      try await clock.sleep(for: .seconds(1))
      await send(.nativeProcessInfoPoll)
    }
    .cancellable(id: CancelID.processInfoPoll, cancelInFlight: true)
  }

  private func nativeResyncEffect(_ state: inout State) -> Effect<Action> {
    state.nativeRequestSequence &+= 1
    let request = HerdrNativeActionRequest(
      requestID: "prowl-native-resync-\(state.nativeRequestSequence)",
      activationEpoch: nil,
      payload: HerdrNativeActionPayload(
        action: "resync",
        endpointKey: nil,
        endpointFence: nil,
        resourceKind: nil,
        resourceID: nil,
        method: nil,
        params: nil
      )
    )
    let client = client
    return .run { _ in try await client.sendNativeAction(request) }
  }

  private func startNativeFocus(
    _ state: inout State,
    endpointKey: HerdrEndpointKey,
    resourceKind: String,
    resourceID: String
  ) -> Effect<Action> {
    guard !resourceID.isEmpty,
      state.aggregateSyncCommitted,
      let endpoint = state.aggregateState?.endpoints.first(where: { $0.endpointKey == endpointKey }
      ),
      endpoint.availability == .enabled,
      endpoint.status == .online,
      endpoint.freshness == .current,
      let fence = nativeFence(for: endpoint)
    else { return .none }

    let isActivation = endpointKey != state.committedActiveEndpointKey
    guard isActivation ? endpoint.activation.canActivate : endpoint.activation.canFocus else {
      return .none
    }
    state.nativeRequestSequence &+= 1
    if isActivation { state.activationEpoch &+= 1 }
    let request = HerdrNativeActionRequest(
      requestID: "prowl-native-focus-\(state.nativeRequestSequence)",
      activationEpoch: isActivation ? state.activationEpoch : nil,
      payload: HerdrNativeActionPayload(
        action: isActivation ? "activate" : "focus",
        endpointKey: endpointKey,
        endpointFence: fence,
        resourceKind: resourceKind,
        resourceID: resourceID,
        method: nil,
        params: nil
      )
    )
    let client = client
    return .run { send in
      do {
        try await client.sendNativeAction(request)
        await send(.focusResponse(.success))
      } catch {
        await send(
          .focusResponse(.failure(.invalidResponse(String(describing: error))))
        )
      }
    }
    .cancellable(id: CancelID.focus, cancelInFlight: true)
  }

  private func startNativeMutation(
    _ state: inout State,
    _ mutation: Mutation
  ) -> Effect<Action> {
    guard state.aggregateSyncCommitted,
      let endpoint = state.aggregateState?.committedEndpoint,
      endpoint.status == .online,
      endpoint.freshness == .current,
      let fence = nativeFence(for: endpoint)
    else { return .none }

    let method: String
    let params: [String: HerdrJSONValue]
    switch mutation {
    case .createWorkspace:
      method = "workspace.create"
      params = ["focus": .bool(true)]
    case .createTab(let workspaceID, let label, let sourceTabID):
      method = "tab.create"
      params = [
        "workspace_id": .string(workspaceID),
        "focus": .bool(true),
        "label": label.map(HerdrJSONValue.string) ?? .null,
        "source_tab_id": sourceTabID.map(HerdrJSONValue.string) ?? .null,
      ]
    case .renameTab(let tabID, let label):
      method = "tab.rename"
      params = ["tab_id": .string(tabID), "label": label.map(HerdrJSONValue.string) ?? .null]
    case .moveTab(let tabID, let insertIndex):
      method = "tab.move"
      params = ["tab_id": .string(tabID), "insert_index": .int(insertIndex)]
    case .closeTab(let tabID, _, _):
      method = "tab.close"
      params = ["tab_id": .string(tabID)]
    case .closeWorkspace(let workspaceID):
      method = "workspace.close"
      params = ["workspace_id": .string(workspaceID), "close_group": .bool(true)]
    }
    guard endpoint.activation.optionalMethods.contains(method) else { return .none }

    state.pendingMutation = mutation
    state.pendingNativeMutationFence = fence
    state.mutationError = nil
    state.mutationGeneration &+= 1
    state.nativeRequestSequence &+= 1
    let generation = state.mutationGeneration
    let requestID = "prowl-native-mutation-\(state.nativeRequestSequence)"
    state.pendingNativeMutationRequestID = requestID
    let request = HerdrNativeActionRequest(
      requestID: requestID,
      activationEpoch: nil,
      payload: HerdrNativeActionPayload(
        action: "mutate",
        endpointKey: endpoint.endpointKey,
        endpointFence: fence,
        resourceKind: nil,
        resourceID: nil,
        method: method,
        params: params
      )
    )
    let client = client
    let clock = clock
    return .run { send in
      do {
        try await client.sendNativeAction(request)
        try await clock.sleep(for: Self.nativeMutationTimeout)
        guard !Task.isCancelled else { return }
        await send(
          .mutationResponse(
            generation,
            .failure(.invalidResponse("Herdr mutation response timed out."))
          )
        )
      } catch is CancellationError {
        return
      } catch {
        await send(
          .mutationResponse(
            generation,
            .failure(.invalidResponse(String(describing: error)))
          )
        )
      }
    }
    .cancellable(id: CancelID.mutation, cancelInFlight: true)
  }

  private func nativeFence(for endpoint: HerdrEndpointProjection) -> HerdrEndpointFence? {
    guard case .concrete(let identity) = endpoint.connectionIdentity,
      let snapshot = endpoint.snapshot,
      snapshot.bootID == identity.serverBootID
    else { return nil }
    return HerdrEndpointFence(
      endpointKey: endpoint.endpointKey,
      identity: identity,
      snapshotRevision: snapshot.revision
    )
  }

  private func startMutation(
    _ state: inout State,
    _ mutation: Mutation
  ) -> Effect<Action> {
    if state.authorityMode == .aggregate {
      return startNativeMutation(&state, mutation)
    }
    state.pendingMutation = mutation
    state.pendingNativeMutationRequestID = nil
    state.pendingNativeMutationFence = nil
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
    invalidatesInFlightRefresh: Bool = false,
    delay: Duration = .milliseconds(100)
  ) -> Effect<Action> {
    if invalidatesInFlightRefresh {
      state.refreshGeneration &+= 1
    }
    let refreshDelay = delay
    let effect = Effect<Action>.run { [clock] send in
      do {
        try await clock.sleep(for: refreshDelay)
        guard !Task.isCancelled else { return }
        await send(.debouncedRefresh)
      } catch {
        return
      }
    }
    .cancellable(id: CancelID.refreshDebounce, cancelInFlight: true)
    return invalidatesInFlightRefresh
      ? .merge(.cancel(id: CancelID.refresh), effect)
      : effect
  }

  private func lifecycleEffect() -> Effect<Action> {
    let client = client
    let clock = clock
    return .run { send in
      var retryDelay = Duration.milliseconds(250)
      while !Task.isCancelled {
        do {
          let discoverySnapshot = try await client.snapshot()
          let subscription = try await client.subscribeEvents(
            Set(discoverySnapshot.panes.map(\.id)))
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
        let currentUptime = ProcessInfo.processInfo.systemUptime
        let elapsedMilliseconds = Int((currentUptime - startedAt) * 1_000)
        herdrTerminalChromeLogger.diagnostic(
          "snapshot-effect-end uptime_ms=\(Int(currentUptime * 1_000)) "
            + "elapsed_ms=\(elapsedMilliseconds) generation=\(generation)"
        )
        await send(.refreshResponseWithGeneration(generation, .success(snapshot)))
      } catch {
        guard !Task.isCancelled else { return }
        let currentUptime = ProcessInfo.processInfo.systemUptime
        let elapsedMilliseconds = Int((currentUptime - startedAt) * 1_000)
        herdrTerminalChromeLogger.diagnostic(
          "snapshot-effect-failure uptime_ms=\(Int(currentUptime * 1_000)) "
            + "elapsed_ms=\(elapsedMilliseconds) generation=\(generation) "
            + "error=\(String(describing: error))"
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
