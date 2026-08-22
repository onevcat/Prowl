import ComposableArchitecture
import Foundation

private let herdrSidebarLogger = SupaLogger("HerdrSidebar")

@Reducer
internal struct HerdrSidebarFeature {
  @ObservableState
  internal struct State: Equatable {
    internal enum Connection: Equatable {
      case hidden
      case connecting
      case connected
      case failed
    }

    internal var connection: Connection = .hidden
    internal var snapshot = HerdrSidebarSnapshot.empty
    internal var selectedWorkspaceID: String?
    internal var selectedTabID: String?
    internal var selectedPaneID: String?
    internal var pendingFocus: FocusTarget?
    internal var refreshGeneration: UInt64 = 0

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

  internal enum Action: Equatable {
    case foregroundChanged(Bool)
    case snapshotResponse(Result<HerdrSidebarSnapshot, HerdrSidebarFailure>)
    case eventStream(HerdrEventStreamState)
    case debouncedRefresh
    case refreshResponse(Result<HerdrSidebarSnapshot, HerdrSidebarFailure>)
    case focusWorkspaceTapped(String)
    case focusTabTapped(String)
    case focusPaneTapped(String)
    case focusResponse(Result<Void, HerdrSidebarFailure>)
    case delegate(DelegateAction)
    case stop
  }

  private enum CancelID: Hashable {
    case lifecycle
    case refreshDebounce
    case refresh
    case focus
  }

  @Dependency(HerdrSidebarClient.self) private var client
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
        replaceSnapshot(&state, with: snapshot)
        state.connection = .connected
        return .none

      case .snapshotResponse(.failure(let failure)):
        guard state.connection != .hidden else { return .none }
        return handleFailure(&state, failure: failure, hidesSidebar: true)

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
        let failure = HerdrSidebarFailure.map(error)
        if failure == .incompatibleProtocol {
          return handleFailure(&state, failure: failure, hidesSidebar: true)
        }
        state.connection = .connecting
        state.snapshot = .empty
        return .none

      case .debouncedRefresh:
        guard state.connection == .connected else { return .none }
        return refreshEffect()
          .cancellable(id: CancelID.refresh, cancelInFlight: true)

      case .refreshResponse(.success(let snapshot)):
        guard state.connection != .hidden else { return .none }
        replaceSnapshot(&state, with: snapshot)
        state.connection = .connected
        return .none

      case .refreshResponse(.failure(let failure)):
        guard state.connection != .hidden else { return .none }
        if failure == .incompatibleProtocol {
          return handleFailure(&state, failure: failure, hidesSidebar: true)
        }
        herdrSidebarLogger.debug("Sidebar refresh failed: \(String(describing: failure))")
        return .none

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
        return refreshEffect()
          .cancellable(id: CancelID.refresh, cancelInFlight: true)

      case .focusResponse(.failure(let failure)):
        state.pendingFocus = nil
        herdrSidebarLogger.warning("Sidebar focus failed: \(String(describing: failure))")
        return .none

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

          for await event in client.events() {
            guard !Task.isCancelled else { return }
            await send(.eventStream(event))
            if case .disconnected = event {
              break
            }
          }
        } catch {
          let failure = HerdrSidebarFailure.map(error)
          guard !Task.isCancelled else { return }
          await send(.snapshotResponse(.failure(failure)))
          if failure == .incompatibleProtocol {
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

  private func refreshEffect() -> Effect<Action> {
    let client = client
    return .run { send in
      do {
        let snapshot = try await client.snapshot()
        guard !Task.isCancelled else { return }
        await send(.refreshResponse(.success(snapshot)))
      } catch {
        guard !Task.isCancelled else { return }
        await send(.refreshResponse(.failure(HerdrSidebarFailure.map(error))))
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
        await send(.focusResponse(.success(())))
      } catch {
        guard !Task.isCancelled else { return }
        await send(.focusResponse(.failure(HerdrSidebarFailure.map(error))))
      }
    }
  }

  private func handleFailure(
    _ state: inout State,
    failure: HerdrSidebarFailure,
    hidesSidebar: Bool
  ) -> Effect<Action> {
    if failure == .incompatibleProtocol {
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
        .send(.delegate(.compatibilityFailure(.unsupportedResponseType(nil))))
      )
    }
    state.connection = hidesSidebar ? .failed : state.connection
    if hidesSidebar {
      state.snapshot = .empty
      state.selectedWorkspaceID = nil
      state.selectedTabID = nil
      state.selectedPaneID = nil
    }
    herdrSidebarLogger.debug("Sidebar unavailable: \(String(describing: failure))")
    return .none
  }

  private func replaceSnapshot(_ state: inout State, with snapshot: HerdrSidebarSnapshot) {
    state.snapshot = snapshot
    state.selectedWorkspaceID = reconciledSelection(
      current: state.selectedWorkspaceID,
      serverFocused: snapshot.focusedWorkspaceID,
      validIDs: Set(snapshot.workspaces.map(\.id))
    )
    state.selectedTabID = reconciledSelection(
      current: state.selectedTabID,
      serverFocused: snapshot.focusedTabID,
      validIDs: Set(snapshot.tabs.map(\.id))
    )
    state.selectedPaneID = reconciledSelection(
      current: state.selectedPaneID,
      serverFocused: snapshot.focusedPaneID,
      validIDs: Set(snapshot.panes.map(\.id))
    )

    guard let pendingFocus = state.pendingFocus else { return }
    let isConfirmed: Bool
    switch pendingFocus {
    case .workspace(let id):
      isConfirmed = snapshot.focusedWorkspaceID == id
    case .tab(let id):
      isConfirmed = snapshot.focusedTabID == id
    case .pane(let id):
      isConfirmed = snapshot.focusedPaneID == id
    }
    guard isConfirmed else { return }
    switch pendingFocus {
    case .workspace(let id):
      state.selectedWorkspaceID = id
    case .tab(let id):
      state.selectedTabID = id
    case .pane(let id):
      state.selectedPaneID = id
    }
    state.pendingFocus = nil
  }

  private func reconciledSelection(
    current: String?,
    serverFocused: String?,
    validIDs: Set<String>
  ) -> String? {
    if let current, validIDs.contains(current) {
      return current
    }
    guard let serverFocused, validIDs.contains(serverFocused) else { return nil }
    return serverFocused
  }
}
