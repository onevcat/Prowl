import ComposableArchitecture
import Testing

@testable import supacode

private struct Counter: Reducer {
  struct State: Equatable {
    var count = 0
    var label = ""
  }

  enum Action: Equatable {
    case increment
    case setLabel(String)
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .increment:
      state.count += 1
      return .none
    case .setLabel(let value):
      state.label = value
      return .none
    }
  }
}

@MainActor
struct LogActionsReducerTests {
  /// With action logging off (the default), the wrapper must reduce exactly like
  /// its base — same state mutation, no diverging behavior from the gated path.
  @Test func passesActionsThroughToBaseWhenLoggingDisabled() async {
    let store = TestStore(initialState: Counter.State()) { LogActionsReducer(base: Counter()) }

    await store.send(.increment) { $0.count = 1 }
    await store.send(.setLabel("repo")) { $0.label = "repo" }
  }

  /// A no-op action leaves state untouched, so the diff branch has nothing to
  /// print; the reducer must still return the base's effect and state.
  @Test func leavesStateUnchangedForActionsThatDoNotMutate() async {
    let store = TestStore(initialState: Counter.State(count: 5, label: "keep")) {
      LogActionsReducer(base: Counter())
    }

    await store.send(.setLabel("keep"))

    #expect(store.state.count == 5)
    #expect(store.state.label == "keep")
  }
}
