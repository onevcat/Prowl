import ComposableArchitecture
import PostHog

@Reducer
struct UpdatesFeature {
  @ObservableState
  struct State: Equatable {
    var didConfigureUpdates = false
    var isUpdateAvailable = false
    var isUpdateReadyToInstall = false
    var availableVersion: String?
  }

  enum Action {
    case task
    case applySettings(automaticallyChecks: Bool)
    case activateUpdateButton
    case checkForUpdates
    case updaterEvent(UpdaterClient.Event)
    #if DEBUG
      case debugSimulateUpdateFound
    #endif
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(UpdaterClient.self) private var updaterClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          for await event in await updaterClient.events() {
            await send(.updaterEvent(event))
          }
        }

      case .applySettings(let checks):
        let checkInBackground = !state.didConfigureUpdates
        state.didConfigureUpdates = true
        return .run { _ in
          await updaterClient.configure(checks, checkInBackground)
        }

      case .activateUpdateButton:
        if state.isUpdateReadyToInstall {
          return installDownloadedUpdate(&state)
        }
        return .send(.checkForUpdates)

      case .checkForUpdates:
        if state.isUpdateReadyToInstall {
          return installDownloadedUpdate(&state)
        }
        analyticsClient.capture("update_checked", nil)
        // Clear the badge so a fresh user-initiated check drives the standard dialog.
        // If the update is still available, Sparkle re-triggers `showUpdateFound` and
        // the standard driver takes over.
        state.isUpdateAvailable = false
        state.isUpdateReadyToInstall = false
        state.availableVersion = nil
        return .run { _ in
          await updaterClient.checkForUpdates()
        }

      case .updaterEvent(.silentUpdateFound(let version)):
        state.isUpdateAvailable = true
        state.isUpdateReadyToInstall = false
        state.availableVersion = version
        return .none

      case .updaterEvent(.downloadedUpdateReadyToInstall(let version)):
        state.isUpdateAvailable = true
        state.isUpdateReadyToInstall = true
        state.availableVersion = version
        return .none

      #if DEBUG
        case .debugSimulateUpdateFound:
          state.isUpdateAvailable = true
          state.isUpdateReadyToInstall = false
          state.availableVersion = "9999.1.1"
          return .none
      #endif
      }
    }
  }

  private func installDownloadedUpdate(_ state: inout State) -> Effect<Action> {
    state.isUpdateAvailable = false
    state.isUpdateReadyToInstall = false
    state.availableVersion = nil
    return .run { _ in
      await updaterClient.installDownloadedUpdate()
    }
  }
}
