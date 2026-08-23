import ComposableArchitecture
import Foundation

@Reducer
internal struct CleanAppFeature {
  @ObservableState
  internal struct State: Equatable {
    internal var settings: SettingsFeature.State
    internal var updates = UpdatesFeature.State()
    internal var herdrTerminalChrome = HerdrTerminalChromeFeature.State()
    @Presents internal var alert: AlertState<Alert>?

    internal init(settings: SettingsFeature.State = .init()) {
      self.settings = settings
    }
  }

  internal enum Action {
    case appLaunched
    case herdrForegroundChanged(Bool)
    case herdrTerminalChrome(HerdrTerminalChromeFeature.Action)
    case herdrCompatibilityFailure(HerdrSocketError)
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
    Scope(state: \.herdrTerminalChrome, action: \.herdrTerminalChrome) {
      HerdrTerminalChromeFeature()
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

      case .herdrCompatibilityFailure(let error):
        guard state.alert == nil else { return .none }
        state.alert = Self.herdrCompatibilityAlert(for: error)
        return .none

      case .herdrForegroundChanged(let isForeground):
        return .send(.herdrTerminalChrome(.foregroundChanged(isForeground)))

      case .herdrTerminalChrome(.delegate(.compatibilityFailure(let error))):
        return .send(.herdrCompatibilityFailure(error))

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

      case .settings, .updates, .herdrTerminalChrome, .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  private static func herdrCompatibilityAlert(for error: HerdrSocketError) -> AlertState<Alert> {
    let message: String
    switch error {
    case .unsupportedProtocol(let supported, let actual):
      let detectedVersion = actual.map(String.init) ?? "unknown"
      message =
        "Prowl Clean requires Herdr protocol \(supported.lowerBound)-\(supported.upperBound), but detected protocol \(detectedVersion). Input-source synchronization is paused. Update Herdr or Prowl."
    case .unsupportedResponseType(let responseType):
      let responseDescription = responseType ?? "unknown"
      message =
        "Prowl Clean could not validate the Herdr protocol response (\(responseDescription)). Input-source synchronization is paused. Update Herdr or Prowl."
    default:
      message =
        "Prowl Clean could not validate the Herdr protocol. Input-source synchronization is paused. Update Herdr or Prowl."
    }

    return AlertState {
      TextState("Herdr protocol incompatible")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState(message)
    }
  }
}
