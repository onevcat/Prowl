import ComposableArchitecture
import DependenciesTestSupport
import Testing

@testable import supacode

@MainActor
struct CleanAppFeatureTests {
  @Test(.dependencies) func launchConfiguresUpdatesWithoutProbingTmux() async {
    let tmuxAvailabilityCheckCount = LockIsolated(0)
    let configuredChannels = LockIsolated<[UpdateChannel]>([])
    let automaticCheckSettings = LockIsolated<[Bool]>([])
    var settings = GlobalSettings.default
    settings.updateChannel = .tip
    settings.updatesAutomaticallyCheckForUpdates = false
    settings.useAnonymousTmuxBackedTerminals = true
    let store = TestStore(
      initialState: CleanAppFeature.State(
        settings: SettingsFeature.State(settings: settings)
      )
    ) {
      CleanAppFeature()
    } withDependencies: {
      $0.tmuxAvailabilityClient.isAvailable = {
        tmuxAvailabilityCheckCount.withValue { $0 += 1 }
        return false
      }
      $0.updaterClient = UpdaterClient(
        configure: { checks, _ in
          automaticCheckSettings.withValue { $0.append(checks) }
        },
        setUpdateChannel: { channel in
          configuredChannels.withValue { $0.append(channel) }
        },
        checkForUpdates: {},
        installDownloadedUpdate: {},
        events: {
          AsyncStream { continuation in
            continuation.finish()
          }
        }
      )
    }
    store.exhaustivity = .off

    await store.send(.appLaunched)
    await store.receive(\.updates.applySettings) {
      $0.updates.didConfigureUpdates = true
    }
    await store.finish()

    #expect(tmuxAvailabilityCheckCount.value == 0)
    #expect(configuredChannels.value == [.tip])
    #expect(automaticCheckSettings.value == [false])
    #expect(store.state.settings.useAnonymousTmuxBackedTerminals)
  }

  @Test(.dependencies) func settingsChangesOnlyConfigureSharedUpdateRuntime() async {
    var settings = GlobalSettings.default
    settings.updateChannel = .tip
    settings.updatesAutomaticallyCheckForUpdates = false
    let store = TestStore(initialState: CleanAppFeature.State()) {
      CleanAppFeature()
    }

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.receive(\.updates.applySettings) {
      $0.updates.didConfigureUpdates = true
    }
  }

  @Test(.dependencies) func quitWithoutConfirmationTerminatesApplication() async {
    let terminationCount = LockIsolated(0)
    var settings = SettingsFeature.State()
    settings.confirmBeforeQuit = false
    let store = TestStore(initialState: CleanAppFeature.State(settings: settings)) {
      CleanAppFeature()
    } withDependencies: {
      $0.appLifecycleClient.terminate = {
        terminationCount.withValue { $0 += 1 }
      }
    }

    await store.send(.requestQuit)
    await store.finish()

    #expect(terminationCount.value == 1)
  }
}
