import ComposableArchitecture
import Foundation

@Reducer
internal struct CleanAppFeature {
  @ObservableState
  internal struct State: Equatable {
    internal var settings: SettingsFeature.State
    internal var updates = UpdatesFeature.State()
    @Presents internal var alert: AlertState<Alert>?

    internal init(settings: SettingsFeature.State = .init()) {
      self.settings = settings
    }
  }

  internal enum Action {
    case appLaunched
    case settings(SettingsFeature.Action)
    case updates(UpdatesFeature.Action)
    case requestQuit
    case alert(PresentationAction<Alert>)
  }

  internal enum Alert: Equatable {
    case confirmQuit
    case dismiss
  }

  @Dependency(AppLifecycleClient.self) private var appLifecycleClient

  internal var body: some Reducer<State, Action> {
    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }
    Scope(state: \.updates, action: \.updates) {
      UpdatesFeature()
    }
    Reduce { state, action in
      switch action {
      case .appLaunched:
        return .merge(
          .send(
            .updates(
              .applySettings(
                updateChannel: state.settings.updateChannel,
                automaticallyChecks: state.settings.updatesAutomaticallyCheckForUpdates
              )
            )
          ),
          .send(.updates(.task))
        )

      case .settings(.delegate(.settingsChanged(let settings))):
        return .send(
          .updates(
            .applySettings(
              updateChannel: settings.updateChannel,
              automaticallyChecks: settings.updatesAutomaticallyCheckForUpdates
            )
          )
        )

      case .settings(.setSelection(.some(.repository))):
        return .send(.settings(.setSelection(.general)))

      case .requestQuit:
        guard state.settings.confirmBeforeQuit else {
          return .run { @MainActor _ in
            appLifecycleClient.terminate()
          }
        }
        _ = appLifecycleClient.surfaceMainWindow()
        state.alert = AlertState {
          TextState("Quit Prowl?")
        } actions: {
          ButtonState(action: .confirmQuit) {
            TextState("Quit")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState("This will close the Clean terminal session.")
        }
        return .none

      case .alert(.presented(.confirmQuit)):
        state.alert = nil
        return .run { @MainActor _ in
          appLifecycleClient.terminate()
        }

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .settings, .updates, .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}
