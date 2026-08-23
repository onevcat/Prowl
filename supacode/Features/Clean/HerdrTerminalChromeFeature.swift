import ComposableArchitecture
import Foundation

private let herdrTerminalChromeLogger = SupaLogger("HerdrTerminalChrome")

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
    internal var pendingMutation: Mutation?
    internal var closeConfirmation: CloseConfirmation?
    internal var mutationError: HerdrTerminalChromeFailure?
    internal var refreshGeneration: UInt64 = 0
    internal var subscribedPaneIDs: Set<String> = []
    internal var mutationGeneration: UInt64 = 0

    internal var isVisible: Bool {
      connection == .connected
    }
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
    case createTab(workspaceID: String, label: String?, sourceTabID: String?)
    case renameTab(tabID: String, label: String)
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
    case newTabRequested(workspaceID: String, label: String?, sourceTabID: String?)
    case renameTabRequested(tabID: String, label: String)
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
    case mutation
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
        state.pendingMutation = nil
        state.closeConfirmation = nil
        state.mutationError = nil
        state.subscribedPaneIDs = []
        state.refreshGeneration &+= 1
        state.mutationGeneration &+= 1
        return .merge(
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.mutation)
        )

      case .foregroundChanged(true):
        state.connection = .connecting
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        state.pendingFocus = nil
        state.pendingMutation = nil
        state.closeConfirmation = nil
        state.mutationError = nil
        state.subscribedPaneIDs = []
        state.refreshGeneration &+= 1
        state.mutationGeneration &+= 1
        return .merge(
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.mutation),
          lifecycleEffect()
            .cancellable(id: CancelID.lifecycle, cancelInFlight: true)
        )

      case .snapshotResponse(.success(let snapshot)):
        guard state.connection != .hidden else { return .none }
        _ = replaceSnapshot(&state, with: snapshot)
        state.connection = .connected
        return .none

      case .snapshotResponse(.failure(let failure)):
        guard state.connection != .hidden else { return .none }
        return handleFailure(&state, failure: failure)

      case .eventStream(.subscribed):
        return .none

      case .eventStream(.event):
        guard state.connection == .connected else { return .none }
        state.refreshGeneration &+= 1
        return .run { [clock] send in
          do {
            try await clock.sleep(for: .milliseconds(100))
          } catch {
            return
          }
          guard !Task.isCancelled else { return }
          await send(.debouncedRefresh)
        }
        .cancellable(id: CancelID.refreshDebounce, cancelInFlight: true)

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
        return .merge(
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
          .cancel(id: CancelID.mutation)
        )

      case .debouncedRefresh:
        guard state.connection == .connected else { return .none }
        return refreshEffect(generation: state.refreshGeneration)
          .cancellable(id: CancelID.refresh, cancelInFlight: true)

      case .refreshResponseWithGeneration(let generation, let result):
        guard generation == state.refreshGeneration else { return .none }
        switch result {
        case .success(let snapshot):
          guard state.connection != .hidden else { return .none }
          let shouldRestartLifecycle = replaceSnapshot(&state, with: snapshot)
          state.connection = .connected
          return shouldRestartLifecycle ? restartLifecycleEffect() : .none
        case .failure(let failure):
          guard state.connection != .hidden else { return .none }
          state.pendingFocus = nil
          if failure.isIncompatibleProtocol {
            return handleFailure(&state, failure: failure)
          }
          state.connection = .connecting
          state.snapshot = .empty
          state.pendingMutation = nil
          state.closeConfirmation = nil
          state.subscribedPaneIDs = []
          state.mutationGeneration &+= 1
          return .merge(
            .cancel(id: CancelID.mutation),
            restartLifecycleEffect()
          )
        }

      case .focusWorkspaceTapped(let workspaceID):
        guard state.connection == .connected else { return .none }
        state.pendingFocus = .workspace(workspaceID)
        return focusEffect(.workspace(workspaceID))
          .cancellable(id: CancelID.focus, cancelInFlight: true)

      case .focusTabTapped(let tabID):
        guard state.connection == .connected else { return .none }
        state.pendingFocus = .tab(tabID)
        return focusEffect(.tab(tabID))
          .cancellable(id: CancelID.focus, cancelInFlight: true)

      case .focusPaneTapped(let paneID):
        guard state.connection == .connected else { return .none }
        state.pendingFocus = .pane(paneID)
        return focusEffect(.pane(paneID))
          .cancellable(id: CancelID.focus, cancelInFlight: true)

      case .focusResponse(.success):
        guard state.pendingFocus != nil else { return .none }
        return refreshEffect(generation: state.refreshGeneration)
          .cancellable(id: CancelID.refresh, cancelInFlight: true)

      case .focusResponse(.failure(let failure)):
        state.pendingFocus = nil
        herdrTerminalChromeLogger.warning("Terminal chrome focus failed: \(String(describing: failure))")
        guard failure.isNotFound else { return .none }
        return refreshEffect(generation: state.refreshGeneration)
          .cancellable(id: CancelID.refresh, cancelInFlight: true)

      case .newTabRequested(let workspaceID, let label, let sourceTabID):
        guard state.connection == .connected else { return .none }
        return startMutation(
          &state,
          .createTab(workspaceID: workspaceID, label: label, sourceTabID: sourceTabID)
        )

      case .renameTabRequested(let tabID, let label):
        guard state.connection == .connected, !label.isEmpty else { return .none }
        return startMutation(&state, .renameTab(tabID: tabID, label: label))

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
          return refreshEffect(generation: state.refreshGeneration)
            .cancellable(id: CancelID.refresh, cancelInFlight: true)
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
            return refreshEffect(generation: state.refreshGeneration)
              .cancellable(id: CancelID.refresh, cancelInFlight: true)
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

  private func lifecycleEffect() -> Effect<Action> {
    let client = client
    let clock = clock
    return .run { send in
      var retryDelay = Duration.milliseconds(250)
      while !Task.isCancelled {
        do {
          let snapshot = try await client.snapshot()
          guard !Task.isCancelled else { return }
          await send(.snapshotResponse(.success(snapshot)))
          retryDelay = .milliseconds(250)

          for await event in client.events(Set(snapshot.panes.map(\.id))) {
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
      do {
        let snapshot = try await client.snapshot()
        guard !Task.isCancelled else { return }
        await send(.refreshResponseWithGeneration(generation, .success(snapshot)))
      } catch {
        guard !Task.isCancelled else { return }
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

  private func handleFailure(
    _ state: inout State,
    failure: HerdrTerminalChromeFailure
  ) -> Effect<Action> {
    if case .incompatibleProtocol(let error) = failure {
      state.connection = .hidden
      state.snapshot = .empty
      state.selectedWorkspaceID = nil
      state.selectedTabID = nil
      state.selectedPaneID = nil
      state.pendingFocus = nil
      state.pendingMutation = nil
      state.closeConfirmation = nil
      state.mutationError = nil
      state.mutationGeneration &+= 1
      return .merge(
        .cancel(id: CancelID.lifecycle),
        .cancel(id: CancelID.refreshDebounce),
        .cancel(id: CancelID.refresh),
        .cancel(id: CancelID.focus),
        .cancel(id: CancelID.mutation),
        .send(.delegate(.compatibilityFailure(error)))
      )
    }
    state.connection = .failed
    state.snapshot = .empty
    state.selectedWorkspaceID = nil
    state.selectedTabID = nil
    state.selectedPaneID = nil
    state.pendingMutation = nil
    state.closeConfirmation = nil
    state.mutationGeneration &+= 1
    herdrTerminalChromeLogger.debug("Terminal chrome unavailable: \(String(describing: failure))")
    return .none
  }

  private func replaceSnapshot(_ state: inout State, with snapshot: HerdrSessionSnapshot) -> Bool {
    let paneIDs = Set(snapshot.panes.map(\.id))
    let shouldRestartLifecycle = paneIDs != state.subscribedPaneIDs
    state.snapshot = snapshot
    state.subscribedPaneIDs = paneIDs
    state.selectedWorkspaceID = reconciledSelection(
      serverFocused: snapshot.focusedWorkspaceID,
      validIDs: Set(snapshot.workspaces.map(\.id))
    )
    state.selectedTabID = reconciledSelection(
      serverFocused: snapshot.focusedTabID,
      validIDs: Set(snapshot.tabs.map(\.id))
    )
    state.selectedPaneID = reconciledSelection(
      serverFocused: snapshot.focusedPaneID,
      validIDs: Set(snapshot.panes.map(\.id))
    )

    guard let pendingFocus = state.pendingFocus else { return shouldRestartLifecycle }
    let isConfirmed: Bool
    switch pendingFocus {
    case .workspace(let id):
      isConfirmed = snapshot.focusedWorkspaceID == id
    case .tab(let id):
      isConfirmed = snapshot.focusedTabID == id
    case .pane(let id):
      isConfirmed = snapshot.focusedPaneID == id
    }
    guard isConfirmed else { return shouldRestartLifecycle }
    switch pendingFocus {
    case .workspace(let id):
      state.selectedWorkspaceID = id
    case .tab(let id):
      state.selectedTabID = id
    case .pane(let id):
      state.selectedPaneID = id
    }
    state.pendingFocus = nil
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
