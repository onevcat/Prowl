import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct SettingsFeatureCLIInstallTests {
  @Test(.dependencies) func installShowsSuccessAlert() async {
    let installed = LockIsolated(false)
    let store = TestStore(
      initialState: SettingsFeature.State()
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.cliInstallClient.install = { _ in
        installed.setValue(true)
      }
      $0.cliInstallClient.installationStatus = { _ in .installed(path: "/usr/local/bin/prowl") }
    }

    await store.send(.installCLIButtonTapped())
    await store.receive(\.cliInstallCompleted.success) {
      $0.alert = AlertState {
        TextState("Command Line Tool Installed")
      } actions: {
        ButtonState(action: .dismiss) { TextState("OK") }
      } message: {
        TextState("The prowl command is now available at /usr/local/bin/prowl.")
      }
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
    }
    await store.receive(\.delegate.cliInstallCompleted)

    #expect(installed.value == true)
  }

  @Test(.dependencies) func installShowsErrorAlertOnFailure() async {
    let store = TestStore(
      initialState: SettingsFeature.State()
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.cliInstallClient.install = { _ in
        throw CLIInstallError(message: "Permission denied")
      }
      $0.cliInstallClient.installationStatus = { _ in .notInstalled }
    }

    await store.send(.installCLIButtonTapped())
    await store.receive(\.cliInstallCompleted.failure) {
      $0.alert = AlertState {
        TextState("Command Line Tool Error")
      } actions: {
        ButtonState(action: .dismiss) { TextState("OK") }
      } message: {
        TextState("Permission denied")
      }
    }
    await store.receive(\.delegate.cliInstallCompleted)
  }

  @Test(.dependencies) func uninstallShowsSuccessAlert() async {
    let uninstalled = LockIsolated(false)
    let store = TestStore(
      initialState: SettingsFeature.State()
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.cliInstallClient.uninstall = { _ in
        uninstalled.setValue(true)
      }
      $0.cliInstallClient.installationStatus = { _ in .notInstalled }
    }

    await store.send(.uninstallCLIButtonTapped)
    await store.receive(\.cliInstallCompleted.success) {
      $0.alert = AlertState {
        TextState("Command Line Tool Uninstalled")
      } actions: {
        ButtonState(action: .dismiss) { TextState("OK") }
      } message: {
        TextState("The prowl command line tool has been removed.")
      }
    }
    await store.receive(\.delegate.cliInstallCompleted)

    #expect(uninstalled.value == true)
  }

  @Test(.dependencies) func commandPaletteInstallRoutesToSettingsAndShowsToast() async {
    let installed = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.cliInstallClient.install = { _ in
        installed.setValue(true)
      }
      $0.cliInstallClient.installationStatus = { _ in .installed(path: "/usr/local/bin/prowl") }
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.installCLI)))
    await store.receive(\.settings.installCLIButtonTapped) {
      $0.settings.cliInstallShowAlert = false
    }
    await store.receive(\.settings.cliInstallCompleted.success) {
      $0.settings.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
    }
    await store.receive(\.settings.delegate.cliInstallCompleted)
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .success("prowl installed at /usr/local/bin/prowl")
    }

    #expect(installed.value == true)
  }
}
