import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct AppFeatureQuitTests {
  @Test(.dependencies) func requestQuitWithConfirmationSurfacesMainWindowAndShowsAlert() async {
    var settings = SettingsFeature.State()
    settings.confirmBeforeQuit = true
    let surfaced = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.setValue(true)
        return true
      }
    }

    await store.send(.requestQuit) {
      $0.alert = AlertState {
        TextState("Quit Prowl?")
      } actions: {
        ButtonState(action: .confirmQuit) {
          TextState("Quit")
        }
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("Cancel")
        }
      } message: {
        TextState("This will close all terminal sessions.")
      }
    }

    #expect(surfaced.value)
  }

  @Test(.dependencies) func requestQuitWithoutConfirmationTerminatesThroughLifecycleClient() async {
    var settings = SettingsFeature.State()
    settings.confirmBeforeQuit = false
    let terminated = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_000)
      $0.appLifecycleClient.terminate = {
        terminated.setValue(true)
      }
    }

    await store.send(.requestQuit)
    await store.finish()

    #expect(terminated.value)
    #expect(store.state.alert == nil)
  }
}
