import ComposableArchitecture
import DependenciesTestSupport
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct UpdatesFeatureTests {
  private struct Configuration: Equatable {
    var checks: Bool
    var checkInBackground: Bool
  }

  @Test(.dependencies) func applySettingsConfiguresAutomaticChecks() async {
    let configuration = LockIsolated<Configuration?>(nil)
    let store = TestStore(initialState: UpdatesFeature.State()) {
      UpdatesFeature()
    } withDependencies: {
      $0.updaterClient.configure = { checks, checkInBackground in
        configuration.withValue {
          $0 = Configuration(checks: checks, checkInBackground: checkInBackground)
        }
      }
    }

    await store.send(.applySettings(automaticallyChecks: true)) {
      $0.didConfigureUpdates = true
    }

    #expect(configuration.value == Configuration(checks: true, checkInBackground: true))
  }

  @Test(.dependencies) func downloadedUpdateEventMarksUpdateReadyToInstall() async {
    let store = TestStore(initialState: UpdatesFeature.State()) {
      UpdatesFeature()
    }

    await store.send(.updaterEvent(.downloadedUpdateReadyToInstall(version: "2026.6.6"))) {
      $0.isUpdateAvailable = true
      $0.isUpdateReadyToInstall = true
      $0.availableVersion = "2026.6.6"
    }
  }

  @Test(.dependencies) func updateButtonInstallsDownloadedUpdateWhenReady() async {
    let installCount = LockIsolated(0)
    var state = UpdatesFeature.State()
    state.isUpdateAvailable = true
    state.isUpdateReadyToInstall = true
    state.availableVersion = "2026.6.6"
    let store = TestStore(initialState: state) {
      UpdatesFeature()
    } withDependencies: {
      $0.updaterClient.installDownloadedUpdate = {
        installCount.withValue { $0 += 1 }
      }
    }

    await store.send(.activateUpdateButton) {
      $0.isUpdateAvailable = false
      $0.isUpdateReadyToInstall = false
      $0.availableVersion = nil
    }

    #expect(installCount.value == 1)
  }

  @Test(.dependencies) func updateButtonChecksForUpdatesWhenOnlyAvailable() async {
    let checkCount = LockIsolated(0)
    var state = UpdatesFeature.State()
    state.isUpdateAvailable = true
    state.availableVersion = "2026.6.6"
    let store = TestStore(initialState: state) {
      UpdatesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
      $0.updaterClient.checkForUpdates = {
        checkCount.withValue { $0 += 1 }
      }
    }

    await store.send(.activateUpdateButton)
    await store.receive(\.checkForUpdates) {
      $0.isUpdateAvailable = false
      $0.availableVersion = nil
    }

    #expect(checkCount.value == 1)
  }

  @Test(.dependencies) func checkForUpdatesInstallsDownloadedUpdateWhenReady() async {
    let checkCount = LockIsolated(0)
    let installCount = LockIsolated(0)
    var state = UpdatesFeature.State()
    state.isUpdateAvailable = true
    state.isUpdateReadyToInstall = true
    state.availableVersion = "2026.6.6"
    let store = TestStore(initialState: state) {
      UpdatesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
      $0.updaterClient.checkForUpdates = {
        checkCount.withValue { $0 += 1 }
      }
      $0.updaterClient.installDownloadedUpdate = {
        installCount.withValue { $0 += 1 }
      }
    }

    await store.send(.checkForUpdates) {
      $0.isUpdateAvailable = false
      $0.isUpdateReadyToInstall = false
      $0.availableVersion = nil
    }

    #expect(checkCount.value == 0)
    #expect(installCount.value == 1)
  }
}
