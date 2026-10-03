import ComposableArchitecture
import Foundation
import Sharing

@Reducer
struct GlobalCustomCommandsFeature {
  @ObservableState
  struct State: Equatable {
    var settings: UserGlobalSettings = .default
    var keybindingUserOverrides: KeybindingUserOverrideStore = .empty
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(UserGlobalSettings, KeybindingUserOverrideStore)
    case binding(BindingAction<State>)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(UserGlobalSettings)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          @Shared(.userGlobalSettings) var settings
          @Shared(.settingsFile) var settingsFile
          await send(.settingsLoaded(settings, settingsFile.global.keybindingUserOverrides))
        }

      case .settingsLoaded(let settings, let overrides):
        state.settings = settings.normalized()
        state.keybindingUserOverrides = overrides
        return .none

      case .binding:
        state.settings = state.settings.normalized()
        return persist(state.settings)

      case .delegate:
        return .none
      }
    }
  }

  private func persist(_ settings: UserGlobalSettings) -> Effect<Action> {
    .run { send in
      @Shared(.userGlobalSettings) var storedSettings
      $storedSettings.withLock { $0 = settings }
      await send(.delegate(.settingsChanged(settings)))
    }
  }
}
