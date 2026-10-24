import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
import Sharing
import Testing

@testable import Prowl

@MainActor
struct ArchivedAutoDeletePeriodSettingsTests {
  @Test(.dependencies) func selectingPeriodAsksParentBeforeApplying() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }

    await store.send(.archivedAutoDeletePeriodSelected(.sevenDays))
    await store.receive(\.delegate.archivedAutoDeletePeriodChangeRequested, .sevenDays)
    #expect(settingsFile.global.archivedAutoDeletePeriod == nil)
  }

  @Test(.dependencies) func selectingCurrentPeriodDoesNothing() async {
    var settings = GlobalSettings.default
    settings.archivedAutoDeletePeriod = .sevenDays
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }

    await store.send(.archivedAutoDeletePeriodSelected(.sevenDays))
  }

  @Test(.dependencies) func selectingNeverAppliesWithoutConfirmation() async {
    var settings = GlobalSettings.default
    settings.archivedAutoDeletePeriod = .sevenDays
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = settings }
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }

    await store.send(.archivedAutoDeletePeriodSelected(nil)) {
      $0.archivedAutoDeletePeriod = nil
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.archivedAutoDeletePeriod == nil)
  }

  @Test(.dependencies) func evaluationWithoutExpiringWorktreesAppliesImmediately() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }

    await store.send(.archivedAutoDeletePeriodChangeEvaluated(.threeDays, expiringWorktreeNames: [])) {
      $0.archivedAutoDeletePeriod = .threeDays
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.archivedAutoDeletePeriod == .threeDays)
  }

  @Test(.dependencies) func evaluationWithExpiringWorktreesAsksForConfirmation() async {
    var settings = GlobalSettings.default
    settings.archivedAutoDeletePeriod = .thirtyDays
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = settings }
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }

    await store.send(
      .archivedAutoDeletePeriodChangeEvaluated(.oneDay, expiringWorktreeNames: ["alpha", "beta"])
    ) {
      $0.pendingArchivedAutoDeletePeriod = .oneDay
      $0.alert = AlertState {
        TextState("Delete 2 archived worktrees now?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchivedAutoDeletePeriod(.oneDay)) {
          TextState("Change and Delete")
        }
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          """
          Changing auto-delete to “After 1 day” permanently deletes these archived worktrees right away. \
          This cannot be undone.

          alpha
          beta
          """
        )
      }
    }
    #expect(store.state.displayedArchivedAutoDeletePeriod == .oneDay)
    #expect(settingsFile.global.archivedAutoDeletePeriod == .thirtyDays)
  }

  @Test(.dependencies) func confirmationListsAtMostTenNames() async {
    let names = (1...12).map { "wt\($0)" }
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }
    store.exhaustivity = .off

    await store.send(.archivedAutoDeletePeriodChangeEvaluated(.oneDay, expiringWorktreeNames: names))
    let message = store.state.alert?.message.map { String(state: $0) } ?? ""
    #expect(message.contains("wt10"))
    #expect(!message.contains("wt11"))
    #expect(message.contains("and 2 more"))
    let title = store.state.alert.map { String(state: $0.title) } ?? ""
    #expect(title == "Delete 12 archived worktrees now?")
  }

  @Test(.dependencies) func singleExpiringWorktreeUsesSingularTitle() async {
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }
    store.exhaustivity = .off

    await store.send(.archivedAutoDeletePeriodChangeEvaluated(.oneDay, expiringWorktreeNames: ["alpha"]))
    let title = store.state.alert.map { String(state: $0.title) } ?? ""
    #expect(title == "Delete 1 archived worktree now?")
  }

  @Test(.dependencies) func confirmingRequestsRevalidationBeforePersistence() async {
    var settings = GlobalSettings.default
    settings.archivedAutoDeletePeriod = .thirtyDays
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = settings }
    var state = SettingsFeature.State(settings: settings)
    state.pendingArchivedAutoDeletePeriod = .oneDay
    state.alert = AlertState { TextState("Delete 2 archived worktrees now?") }
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.alert(.presented(.confirmArchivedAutoDeletePeriod(.oneDay)))) {
      $0.alert = nil
    }
    await store.receive(\.delegate.archivedAutoDeleteConfirmationRequested)
    #expect(settingsFile.global.archivedAutoDeletePeriod == .thirtyDays)
  }

  @Test(.dependencies) func cancellingKeepsPreviousPeriod() async {
    var settings = GlobalSettings.default
    settings.archivedAutoDeletePeriod = .thirtyDays
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = settings }
    var state = SettingsFeature.State(settings: settings)
    state.pendingArchivedAutoDeletePeriod = .oneDay
    state.alert = AlertState { TextState("Delete 2 archived worktrees now?") }
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    // The Cancel button carries the `.dismiss` alert action.
    await store.send(.alert(.presented(.dismiss))) {
      $0.alert = nil
      $0.pendingArchivedAutoDeletePeriod = nil
    }
    #expect(store.state.displayedArchivedAutoDeletePeriod == .thirtyDays)
    #expect(store.state.archivedAutoDeletePeriod == .thirtyDays)
    #expect(settingsFile.global.archivedAutoDeletePeriod == .thirtyDays)
  }

  @Test(.dependencies) func viewDismissWritebackAlsoCancelsPendingPeriod() async {
    var settings = GlobalSettings.default
    settings.archivedAutoDeletePeriod = .thirtyDays
    var state = SettingsFeature.State(settings: settings)
    state.pendingArchivedAutoDeletePeriod = .oneDay
    state.alert = AlertState { TextState("Delete 2 archived worktrees now?") }
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.alert(.dismiss)) {
      $0.alert = nil
      $0.pendingArchivedAutoDeletePeriod = nil
    }
  }

  @Test(.dependencies) func replacingConfirmationWithAnotherAlertDropsPendingPeriodOnItsAction() async {
    var settings = GlobalSettings.default
    settings.archivedAutoDeletePeriod = .thirtyDays
    var state = SettingsFeature.State(settings: settings)
    state.pendingArchivedAutoDeletePeriod = .oneDay
    state.alert = AlertState { TextState("Delete 2 archived worktrees now?") }
    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.systemNotificationClient.openSettings = {}
    }

    await store.send(.showNotificationPermissionAlert(errorMessage: nil)) {
      $0.alert = AlertState {
        TextState("Prowl cannot send system notifications")
      } actions: {
        ButtonState(action: .openSystemNotificationSettings) {
          TextState("Open System Settings")
        }
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "Notification permission is turned off. Open System Settings to allow Prowl to send notifications."
        )
      }
    }
    await store.send(.alert(.presented(.openSystemNotificationSettings))) {
      $0.alert = nil
      $0.pendingArchivedAutoDeletePeriod = nil
    }
    #expect(store.state.displayedArchivedAutoDeletePeriod == .thirtyDays)
  }
}

nonisolated private let archivedAutoDeleteTestNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite(
  .dependency(\.date.now, archivedAutoDeleteTestNow),
  .dependencies {
    $0[WorkflowHistoryStorageKey.self] = WorkflowHistoryStorage(
      baseURL: FileManager.default.temporaryDirectory.appending(path: "workflow-history-\(UUID().uuidString)"))
  }
)
@MainActor
struct ArchivedAutoDeletePeriodAppTests {
  private func makeWorktree(_ name: String, repoRoot: String) -> Worktree {
    let path = name == "main" ? repoRoot : "\(repoRoot)/\(name)"
    return Worktree(
      id: path,
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(_ root: String, name: String, worktrees: [Worktree]) -> Repository {
    Repository(
      id: root,
      rootURL: URL(fileURLWithPath: root),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private func daysAgo(_ days: Double) -> Date {
    archivedAutoDeleteTestNow.addingTimeInterval(-days * 86_400)
  }

  private func makeState(currentPeriod: AutoDeletePeriod?) -> AppFeature.State {
    let first = makeRepository(
      "/tmp/first",
      name: "first",
      worktrees: [
        makeWorktree("main", repoRoot: "/tmp/first"),
        makeWorktree("old-alpha", repoRoot: "/tmp/first"),
        makeWorktree("recent", repoRoot: "/tmp/first"),
      ]
    )
    let second = makeRepository(
      "/tmp/second",
      name: "second",
      worktrees: [
        makeWorktree("main", repoRoot: "/tmp/second"),
        makeWorktree("old-beta", repoRoot: "/tmp/second"),
      ]
    )
    var repositories = RepositoriesFeature.State(repositories: [first, second])
    repositories.archivedWorktrees = [
      ArchivedWorktree(id: "/tmp/first/old-alpha", archivedAt: daysAgo(10)),
      ArchivedWorktree(id: "/tmp/first/recent", archivedAt: daysAgo(1)),
      ArchivedWorktree(id: "/tmp/second/old-beta", archivedAt: daysAgo(20)),
      // The main worktree is never auto-deleted, so it must not appear in the warning.
      ArchivedWorktree(id: "/tmp/second", archivedAt: daysAgo(40)),
    ]
    repositories.archivedAutoDeletePeriod = currentPeriod
    var settingsState = GlobalSettings.default
    settingsState.archivedAutoDeletePeriod = currentPeriod
    return AppFeature.State(repositories: repositories, settings: SettingsFeature.State(settings: settingsState))
  }

  @Test(.dependencies) func changeRequestReportsArchivedWorktreesThatWouldExpireAcrossRepositories() async {
    let store = TestStore(initialState: makeState(currentPeriod: nil)) {
      AppFeature()
    }

    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.sevenDays))))
    await store.receive(
      \.settings.archivedAutoDeletePeriodChangeEvaluated
    ) {
      $0.settings.pendingArchivedAutoDeletePeriod = .sevenDays
      $0.settings.pendingArchivedAutoDeleteTargets = [
        ArchivedAutoDeleteTarget(worktreeID: "/tmp/first/old-alpha", repositoryID: "/tmp/first"),
        ArchivedAutoDeleteTarget(worktreeID: "/tmp/second/old-beta", repositoryID: "/tmp/second"),
      ]
      $0.settings.alert = AlertState {
        TextState("Delete 2 archived worktrees now?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmArchivedAutoDeletePeriod(.sevenDays)) {
          TextState("Change and Delete")
        }
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          """
          Changing auto-delete to “After 7 days” permanently deletes these archived worktrees right away. \
          This cannot be undone.

          first / old-alpha
          second / old-beta
          """
        )
      }
    }
    #expect(store.state.repositories.archivedAutoDeletePeriod == nil)
    #expect(store.state.repositories.archivedWorktrees.count == 4)
    await store.finish()
  }

  @Test(.dependencies) func changeRequestWithNothingToExpireAppliesPeriod() async {
    let store = TestStore(initialState: makeState(currentPeriod: .sevenDays)) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.thirtyDays))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated) {
      $0.settings.archivedAutoDeletePeriod = .thirtyDays
    }
    await store.receive(\.settings.delegate.settingsChanged)
    await store.receive(\.repositories.setArchivedAutoDeletePeriod) {
      $0.repositories.archivedAutoDeletePeriod = .thirtyDays
    }
    #expect(store.state.settings.alert == nil)
  }

  @Test(.dependencies) func confirmingDeletesOnlyTheListedArchivedWorktrees() async {
    let removed = LockIsolated<[Worktree.ID]>([])
    let store = TestStore(initialState: makeState(currentPeriod: nil)) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0.append(worktree.id) }
        return worktree.localURL!
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.sevenDays))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    await store.send(.settings(.alert(.presented(.confirmArchivedAutoDeletePeriod(.sevenDays))))) {
      $0.settings.alert = nil
    }
    await store.receive(\.repositories.setArchivedAutoDeletePeriod) {
      $0.repositories.archivedAutoDeletePeriod = .sevenDays
    }
    await store.receive(\.repositories.deleteExpiredArchivedWorktree)
    await store.receive(\.repositories.deleteExpiredArchivedWorktree)
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.skipReceivedActions()
    #expect(Set(removed.value) == ["/tmp/first/old-alpha", "/tmp/second/old-beta"])
    #expect(
      store.state.repositories.archivedWorktrees.map(\.id).sorted() == ["/tmp/first/recent", "/tmp/second"]
    )
  }

  @Test(.dependencies) func newlyExpiredTargetRequiresAnotherConfirmation() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    let date = LockIsolated(archivedAutoDeleteTestNow)
    let removed = LockIsolated<[Worktree.ID]>([])
    let store = TestStore(initialState: makeState(currentPeriod: nil)) {
      AppFeature()
    } withDependencies: {
      $0.date = DateGenerator { date.value }
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0.append(worktree.id) }
        return worktree.localURL!
      }
    }
    store.exhaustivity = .off
    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.sevenDays))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    date.withValue { $0 = $0.addingTimeInterval(7 * 86_400) }
    await store.send(.settings(.alert(.presented(.confirmArchivedAutoDeletePeriod(.sevenDays)))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    #expect(settingsFile.global.archivedAutoDeletePeriod == nil)
    #expect(store.state.repositories.archivedAutoDeletePeriod == nil)
    #expect(String(customDumping: store.state.settings.alert).contains("recent"))
    #expect(removed.value.isEmpty)
    await store.send(.settings(.alert(.presented(.confirmArchivedAutoDeletePeriod(.sevenDays)))))
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.skipReceivedActions()
    #expect(settingsFile.global.archivedAutoDeletePeriod == .sevenDays)
    #expect(Set(removed.value) == ["/tmp/first/old-alpha", "/tmp/second/old-beta", "/tmp/first/recent"])
  }

  @Test(.dependencies) func expiryAfterAcceptanceDoesNotExpandInitialCleanup() async {
    let date = LockIsolated(archivedAutoDeleteTestNow)
    let removed = LockIsolated<[Worktree.ID]>([])
    let store = TestStore(initialState: makeState(currentPeriod: nil)) {
      AppFeature()
    } withDependencies: {
      $0.date = DateGenerator { date.value }
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0.append(worktree.id) }
        return worktree.localURL!
      }
    }
    store.exhaustivity = .off
    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.sevenDays))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    await store.send(.settings(.alert(.presented(.confirmArchivedAutoDeletePeriod(.sevenDays)))))
    await store.receive(\.settings.applyArchivedAutoDeletePeriod)
    // The accepted snapshot must survive settingsChanged and setArchivedAutoDeletePeriod effects.
    date.withValue { $0 = $0.addingTimeInterval(7 * 86_400) }
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.skipReceivedActions()
    #expect(Set(removed.value) == ["/tmp/first/old-alpha", "/tmp/second/old-beta"])
    #expect(store.state.repositories.archivedWorktrees.contains { $0.id == "/tmp/first/recent" })
  }

  @Test(.dependencies) func repositoryRefreshAddsTargetAndRequiresAnotherConfirmation() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    var state = makeState(currentPeriod: nil)
    let restored = makeWorktree("restored", repoRoot: "/tmp/first")
    state.repositories.archivedWorktrees.append(ArchivedWorktree(id: restored.id, archivedAt: daysAgo(20)))
    var refreshed = Array(state.repositories.repositories)
    refreshed[0] = makeRepository(
      "/tmp/first", name: "first", worktrees: Array(refreshed[0].worktrees) + [restored]
    )
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off
    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.sevenDays))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    await store.send(
      .repositories(
        .repositoriesLoaded(
          refreshed, failures: [], roots: refreshed.map(\.localURL!), animated: false
        )))
    await store.send(.settings(.alert(.presented(.confirmArchivedAutoDeletePeriod(.sevenDays)))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    #expect(settingsFile.global.archivedAutoDeletePeriod == nil)
    #expect(store.state.repositories.deletingWorktreeIDs.isEmpty)
    #expect(
      store.state.settings.pendingArchivedAutoDeleteTargets.contains(
        ArchivedAutoDeleteTarget(worktreeID: restored.id, repositoryID: "/tmp/first")
      ))
    #expect(String(customDumping: store.state.settings.alert).contains("restored"))
    await store.send(.settings(.alert(.presented(.dismiss))))
    await store.finish()
  }

  @Test(.dependencies) func unarchivingBeforeConfirmationExcludesTarget() async {
    let removed = LockIsolated<[Worktree.ID]>([])
    let store = TestStore(initialState: makeState(currentPeriod: nil)) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0.append(worktree.id) }
        return worktree.localURL!
      }
    }
    store.exhaustivity = .off
    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.sevenDays))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    await store.send(.repositories(.worktreeLifecycle(.unarchiveWorktree("/tmp/first/old-alpha"))))
    await store.send(.settings(.alert(.presented(.confirmArchivedAutoDeletePeriod(.sevenDays)))))
    await store.receive(\.repositories.worktreeLifecycle.worktreeDeleted)
    await store.skipReceivedActions()
    #expect(removed.value == ["/tmp/second/old-beta"])
    #expect(store.state.settings.archivedAutoDeletePeriod == .sevenDays)
  }

  @Test(.dependencies) func initialCleanupUsesAcceptedSnapshotButLaterCleanupUsesCurrentExpiry() async {
    let removed = LockIsolated<[Worktree.ID]>([])
    // All three are now expired, but only alpha was in the accepted snapshot.
    let store = TestStore(initialState: makeState(currentPeriod: nil).repositories) {
      RepositoriesFeature()
    } withDependencies: {
      $0.date.now = archivedAutoDeleteTestNow.addingTimeInterval(7 * 86_400)
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0.append(worktree.id) }
        return worktree.localURL!
      }
    }
    store.exhaustivity = .off
    await store.send(
      .setArchivedAutoDeletePeriod(
        .sevenDays,
        initialTargets: [
          ArchivedAutoDeleteTarget(worktreeID: "/tmp/first/old-alpha", repositoryID: "/tmp/first")
        ]))
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
    await store.skipReceivedActions()
    #expect(removed.value == ["/tmp/first/old-alpha"])
    await store.send(.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
    await store.receive(\.worktreeLifecycle.worktreeDeleted)
    await store.skipReceivedActions()
    #expect(Set(removed.value) == ["/tmp/first/old-alpha", "/tmp/second/old-beta", "/tmp/first/recent"])
  }

  @Test(.dependencies, arguments: [false, true])
  func initialCleanupRechecksUnarchivedOrRemovedTargets(removedFromRepository: Bool) async {
    var state = makeState(currentPeriod: .sevenDays).repositories
    let target = ArchivedAutoDeleteTarget(worktreeID: "/tmp/first/old-alpha", repositoryID: "/tmp/first")
    if removedFromRepository {
      state.repositories[id: target.repositoryID] = makeRepository(
        "/tmp/first", name: "first",
        worktrees: state.repositories[id: target.repositoryID]!.worktrees.filter { $0.id != target.worktreeID }
      )
    } else {
      state.archivedWorktrees.removeAll { $0.id == target.worktreeID }
    }
    let store = TestStore(initialState: state) { RepositoriesFeature() }
    await store.send(.deleteExpiredArchivedWorktree(target, period: .sevenDays))
    #expect(store.state.deletingWorktreeIDs.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func cancellingLeavesRepositoriesUntouched() async {
    let store = TestStore(initialState: makeState(currentPeriod: nil)) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in
        Issue.record("Cancelled change must not delete \(worktree.id)")
        return worktree.localURL!
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.archivedAutoDeletePeriodChangeRequested(.sevenDays))))
    await store.receive(\.settings.archivedAutoDeletePeriodChangeEvaluated)
    await store.send(.settings(.alert(.presented(.dismiss)))) {
      $0.settings.alert = nil
      $0.settings.pendingArchivedAutoDeletePeriod = nil
      $0.settings.pendingArchivedAutoDeleteTargets = []
    }
    await store.finish()
    #expect(store.state.settings.archivedAutoDeletePeriod == nil)
    #expect(store.state.repositories.archivedAutoDeletePeriod == nil)
    #expect(store.state.repositories.archivedWorktrees.count == 4)
  }

  @Test func expiredArchivedWorktreesSkipsDeletingAndUnknownEntries() {
    var state = makeState(currentPeriod: nil).repositories
    state.deletingWorktreeIDs = ["/tmp/second/old-beta"]
    state.archivedWorktrees.append(ArchivedWorktree(id: "/tmp/gone/orphan", archivedAt: daysAgo(30)))

    let expired = state.expiredArchivedWorktrees(for: .sevenDays, now: archivedAutoDeleteTestNow)

    #expect(expired.map(\.worktree.id) == ["/tmp/first/old-alpha"])
    #expect(expired.map(\.repository.id) == ["/tmp/first"])
  }
}
