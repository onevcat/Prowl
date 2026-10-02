import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

private struct SystemNotificationSend: Equatable {
  let title: String
  let body: String
  let worktreeID: Worktree.ID?
  let surfaceID: UUID?
}

@MainActor
struct AppFeatureSystemNotificationTests {
  @Test(.dependencies) func firstTimeDeniedTurnsSystemNotificationsBackOffWithAlert() async {
    let storage = SettingsTestStorage()
    let authorizationRequests = LockIsolated(0)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      } withDependencies: {
        $0.systemNotificationClient.authorizationStatus = { .notDetermined }
        $0.systemNotificationClient.requestAuthorization = {
          authorizationRequests.withValue { $0 += 1 }
          return SystemNotificationClient.AuthorizationRequestResult(
            granted: false,
            errorMessage: "Mock request error"
          )
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.binding(.set(\.systemNotificationsEnabled, true)))) {
      $0.settings.systemNotificationsEnabled = true
    }
    await store.receive(\.systemNotificationsPermissionFailed)
    await store.receive(\.settings.setSystemNotificationsEnabled) {
      $0.settings.systemNotificationsEnabled = false
    }
    let expectedAlert = AlertState<SettingsFeature.Alert> {
      TextState("Prowl cannot send system notifications")
    } actions: {
      ButtonState(action: .openSystemNotificationSettings) {
        TextState("Open System Settings")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("Notification permission is turned off. Open System Settings to allow Prowl to send notifications.")
    }
    await store.receive(\.settings.showNotificationPermissionAlert) {
      $0.settings.alert = expectedAlert
    }

    #expect(authorizationRequests.value == 1)
    #expect(store.state.settings.systemNotificationsEnabled == false)
    #expect(store.state.settings.alert == expectedAlert)
  }

  @Test(.dependencies) func deniedStatusShowsAlertAndOpensSystemSettings() async {
    let storage = SettingsTestStorage()
    let authorizationRequests = LockIsolated(0)
    let openedSettings = LockIsolated(0)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      } withDependencies: {
        $0.systemNotificationClient.authorizationStatus = { .denied }
        $0.systemNotificationClient.requestAuthorization = {
          authorizationRequests.withValue { $0 += 1 }
          return SystemNotificationClient.AuthorizationRequestResult(
            granted: false,
            errorMessage: "Mock request error"
          )
        }
        $0.systemNotificationClient.openSettings = {
          openedSettings.withValue { $0 += 1 }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.binding(.set(\.systemNotificationsEnabled, true)))) {
      $0.settings.systemNotificationsEnabled = true
    }
    await store.receive(\.systemNotificationsPermissionFailed)
    await store.receive(\.settings.setSystemNotificationsEnabled) {
      $0.settings.systemNotificationsEnabled = false
    }
    let expectedAlert = AlertState<SettingsFeature.Alert> {
      TextState("Prowl cannot send system notifications")
    } actions: {
      ButtonState(action: .openSystemNotificationSettings) {
        TextState("Open System Settings")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("Notification permission is turned off. Open System Settings to allow Prowl to send notifications.")
    }
    await store.receive(\.settings.showNotificationPermissionAlert) {
      $0.settings.alert = expectedAlert
    }

    #expect(authorizationRequests.value == 0)
    #expect(store.state.settings.systemNotificationsEnabled == false)
    #expect(store.state.settings.alert == expectedAlert)

    await store.send(.settings(.alert(.presented(.openSystemNotificationSettings)))) {
      $0.settings.alert = nil
    }
    await store.finish()
    #expect(openedSettings.value == 1)
  }

  @Test(.dependencies) func notificationReceivedSendsSystemNotificationWhenEnabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let surfaceID = UUID()
    let sends = LockIsolated<[SystemNotificationSend]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { title, body, worktreeID, targetSurfaceID in
        sends.withValue {
          $0.append(
            SystemNotificationSend(
              title: title,
              body: body,
              worktreeID: worktreeID,
              surfaceID: targetSurfaceID
            )
          )
        }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: surfaceID,
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    #expect(sends.value.count == 1)
    #expect(sends.value.first?.title == "Done")
    #expect(sends.value.first?.body == "Build succeeded")
    #expect(sends.value.first?.worktreeID == "/tmp/repo/wt-1")
    #expect(sends.value.first?.surfaceID == surfaceID)
  }

  @Test(.dependencies) func notificationMutedForViewedSurfaceSkipsBannerSoundAndBounce() async {
    var globalSettings = GlobalSettings.default
    globalSettings.muteNotificationsForActiveSurface = true
    globalSettings.systemNotificationsEnabled = true
    globalSettings.notificationSound = .funk
    globalSettings.dockBounceMode = .once
    let sends = LockIsolated(0)
    let plays = LockIsolated(0)
    let bounces = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { _, _, _, _ in sends.withValue { $0 += 1 } }
      $0.notificationSoundClient.play = { _ in plays.withValue { $0 += 1 } }
      $0.dockClient.bounce = { _ in bounces.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: true
        )
      )
    )
    await store.finish()

    // The user is already looking at the pane, so no attention-grabbing channel fires.
    #expect(sends.value == 0)
    #expect(plays.value == 0)
    #expect(bounces.value == 0)
  }

  @Test(.dependencies) func notificationForViewedSurfaceStillNotifiesWhenMuteDisabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.muteNotificationsForActiveSurface = false
    globalSettings.systemNotificationsEnabled = true
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { _, _, _, _ in sends.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: true
        )
      )
    )
    await store.finish()

    // Mute is off, so a viewed surface still posts the banner.
    #expect(sends.value == 1)
  }

  @Test(.dependencies) func notificationReceivedSkipsLocalSoundWhenSystemNotificationsEnabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let plays = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { _ in
        plays.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    #expect(plays.value == 0)
  }

  @Test(.dependencies) func notificationReceivedPlaysLocalSoundWhenSystemNotificationsDisabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = false
    globalSettings.notificationSound = .funk
    let plays = LockIsolated<[NotificationSound]>([])
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { sound in
        plays.withValue { $0.append(sound) }
      }
      $0.systemNotificationClient.send = { _, _, _, _ in
        sends.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    // The selected sound reaches the player unchanged.
    #expect(plays.value == [.funk])
    #expect(sends.value == 0)
  }

  @Test(.dependencies) func notificationReceivedSkipsLocalSoundWhenNever() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = false
    globalSettings.notificationSound = .never
    let plays = LockIsolated<[NotificationSound]>([])
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { sound in
        plays.withValue { $0.append(sound) }
      }
      $0.systemNotificationClient.send = { _, _, _, _ in
        sends.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    #expect(plays.value.isEmpty)
    #expect(sends.value == 0)
  }
}
