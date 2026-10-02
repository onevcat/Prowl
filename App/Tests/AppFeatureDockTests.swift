import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct AppFeatureDockTests {
  private func notificationReceived() -> AppFeature.Action {
    .terminalEvent(
      .notificationReceived(
        worktreeID: "/tmp/repo/wt-1",
        surfaceID: UUID(),
        title: "Done",
        body: "Build succeeded",
        isViewed: false
      )
    )
  }

  @Test(.dependencies) func notificationReceivedBouncesOnceWhenModeIsOnce() async {
    var globalSettings = GlobalSettings.default
    globalSettings.dockBounceMode = .once
    let bounces = LockIsolated<[DockBounceMode]>([])
    let store = TestStore(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: globalSettings))
    ) {
      AppFeature()
    } withDependencies: {
      $0.dockClient.bounce = { mode in bounces.withValue { $0.append(mode) } }
    }
    store.exhaustivity = .off

    await store.send(notificationReceived())
    await store.finish()

    #expect(bounces.value == [.once])
  }

  @Test(.dependencies) func notificationReceivedBouncesContinuouslyWhenModeIsContinuous() async {
    var globalSettings = GlobalSettings.default
    globalSettings.dockBounceMode = .continuous
    let bounces = LockIsolated<[DockBounceMode]>([])
    let store = TestStore(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: globalSettings))
    ) {
      AppFeature()
    } withDependencies: {
      $0.dockClient.bounce = { mode in bounces.withValue { $0.append(mode) } }
    }
    store.exhaustivity = .off

    await store.send(notificationReceived())
    await store.finish()

    #expect(bounces.value == [.continuous])
  }

  @Test(.dependencies) func notificationReceivedDoesNotBounceWhenModeIsOff() async {
    // `.off` is the default; no bounce effect should be scheduled at all.
    let globalSettings = GlobalSettings.default
    let bounces = LockIsolated<[DockBounceMode]>([])
    let store = TestStore(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: globalSettings))
    ) {
      AppFeature()
    } withDependencies: {
      $0.dockClient.bounce = { mode in bounces.withValue { $0.append(mode) } }
    }
    store.exhaustivity = .off

    await store.send(notificationReceived())
    await store.finish()

    #expect(bounces.value.isEmpty)
  }

  @Test(.dependencies) func indicatorChangeShowsBadgeWhenEnabledAndCountPositive() async {
    var globalSettings = GlobalSettings.default
    globalSettings.showNotificationDotOnDock = true
    let badges = LockIsolated<[Int]>([])
    let store = TestStore(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: globalSettings))
    ) {
      AppFeature()
    } withDependencies: {
      $0.dockClient.setNotificationBadge = { count in badges.withValue { $0.append(count) } }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.notificationIndicatorChanged(count: 2))) {
      $0.notificationIndicatorCount = 2
    }
    await store.finish()

    #expect(badges.value == [2])
  }

  @Test(.dependencies) func indicatorChangeClearsBadgeWhenDisabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.showNotificationDotOnDock = false
    let badges = LockIsolated<[Int]>([])
    let store = TestStore(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: globalSettings))
    ) {
      AppFeature()
    } withDependencies: {
      $0.dockClient.setNotificationBadge = { count in badges.withValue { $0.append(count) } }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.notificationIndicatorChanged(count: 3))) {
      $0.notificationIndicatorCount = 3
    }
    await store.finish()

    #expect(badges.value == [0])
  }

  @Test(.dependencies) func indicatorChangeClearsBadgeWhenCountZero() async {
    var globalSettings = GlobalSettings.default
    globalSettings.showNotificationDotOnDock = true
    let badges = LockIsolated<[Int]>([])
    let store = TestStore(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: globalSettings))
    ) {
      AppFeature()
    } withDependencies: {
      $0.dockClient.setNotificationBadge = { count in badges.withValue { $0.append(count) } }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.notificationIndicatorChanged(count: 0)))
    await store.finish()

    #expect(badges.value == [0])
  }
}
