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
    internal var refreshGeneration: UInt64 = 0
    internal var subscribedPaneIDs: Set<String> = []

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
    case delegate(DelegateAction)
    case stop
  }

  nonisolated private enum CancelID: Hashable, Sendable {
    case lifecycle
    case refreshDebounce
    case refresh
    case focus
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
        state.subscribedPaneIDs = []
        state.refreshGeneration &+= 1
        return .merge(
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus)
        )

      case .foregroundChanged(true):
        state.connection = .connecting
        state.snapshot = .empty
        state.selectedWorkspaceID = nil
        state.selectedTabID = nil
        state.selectedPaneID = nil
        state.pendingFocus = nil
        state.subscribedPaneIDs = []
        state.refreshGeneration &+= 1
        return .merge(
          .cancel(id: CancelID.lifecycle),
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus),
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
        state.connection = .connecting
        state.snapshot = .empty
        state.subscribedPaneIDs = []
        return .merge(
          .cancel(id: CancelID.refreshDebounce),
          .cancel(id: CancelID.refresh),
          .cancel(id: CancelID.focus)
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
          state.subscribedPaneIDs = []
          return restartLifecycleEffect()
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

      case .delegate:
        return .none
      }
    }
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
      return .merge(
        .cancel(id: CancelID.lifecycle),
        .cancel(id: CancelID.refreshDebounce),
        .cancel(id: CancelID.refresh),
        .cancel(id: CancelID.focus),
        .send(.delegate(.compatibilityFailure(error)))
      )
    }
    state.connection = .failed
    state.snapshot = .empty
    state.selectedWorkspaceID = nil
    state.selectedTabID = nil
    state.selectedPaneID = nil
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
