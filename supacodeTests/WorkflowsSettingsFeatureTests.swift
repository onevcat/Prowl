import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct WorkflowsSettingsFeatureTests {
  private static let review = """
    schema: prowl.workflow/v1
    id: review
    name: Review
    roles:
      author:
        source: current
      reviewer:
        source: launch
        agents: [codex]
    steps:
      - id: launch
        launch: reviewer
        prompt: "Review."
    """

  private static let codexProfile = AgentProfile(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Codex Review",
    runtime: .codex)
  private static let baseSettings = UserGlobalSettings(
    customCommands: [], agentProfiles: [codexProfile])

  /// Temp user and repo directories, a client that scans them for real, and hooks to observe reveals
  /// and drive the directory watcher.
  private final class Fixture: @unchecked Sendable {
    let root: URL
    let userDirectory: URL
    let repoRoot: URL
    let revealed = LockIsolated<[URL]>([])
    let opened = LockIsolated<[URL]>([])
    let watchContinuations = LockIsolated<[AsyncStream<Void>.Continuation]>([])
    var scanError: WorkflowSettingsError?

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(
          path: "prowl-workflows-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
      userDirectory = root.appending(path: "home/.prowl/workflows", directoryHint: .isDirectory)
      repoRoot = root.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }

    func write(_ yaml: String, to name: String) throws {
      try Data(yaml.utf8).write(
        to: userDirectory.appending(path: name, directoryHint: .notDirectory))
    }

    func scan() throws -> WorkflowSettingsScan {
      if let scanError { throw scanError }
      let context = { (scope: WorkflowScope) in WorkflowValidationContext(scope: scope) }
      let repoDirectory = WorkflowSources.repoDirectory(root: repoRoot)
      return WorkflowSettingsScan(
        bundleDirectory: nil,
        userDirectory: userDirectory,
        entries: try WorkflowDiscovery.catalog(
          sources: WorkflowSources(bundle: nil, user: userDirectory, repo: nil), context: context),
        repositories: [
          WorkflowSettingsRepositoryScan(
            repositoryID: "repo", name: "Repo", rootPath: repoRoot.path(percentEncoded: false),
            directory: repoDirectory,
            entries: try WorkflowDiscovery.catalog(
              sources: WorkflowSources(bundle: nil, user: userDirectory, repo: repoDirectory),
              context: context))
        ])
    }

    var client: WorkflowSettingsClient {
      WorkflowSettingsClient(
        scan: { _ in try self.scan() },
        createWorkflow: { directory in try WorkflowStarterTemplate.write(in: directory) },
        runTargets: { _ in [] },
        reveal: { url in self.revealed.withValue { $0.append(url) } },
        watch: { _ in
          let (stream, continuation) = AsyncStream<Void>.makeStream()
          self.watchContinuations.withValue { $0.append(continuation) }
          return stream
        })
    }

    func finishWatchers() {
      watchContinuations.withValue { continuations in
        for continuation in continuations {
          continuation.finish()
        }
        continuations.removeAll()
      }
    }

    /// The rows for explicit settings — the TestStore's expectation closure reads `@Shared`
    /// as it was before the action, so expectations are built from the settings they expect.
    func expectedCatalog(_ settings: UserGlobalSettings = baseSettings) throws
      -> WorkflowSettingsCatalog
    {
      WorkflowSettingsCatalog.build(scan: try scan(), settings: settings)
    }
  }

  private func makeStore(
    _ fixture: Fixture,
    storage: SettingsTestStorage,
    clock: TestClock<Duration> = TestClock(),
    serviceStatus: CLIServiceStatus = .listening(path: "/tmp/cli.sock"),
    installStatus: CLIInstallStatus = .installed(path: "/usr/local/bin/prowl"),
    cliUsable: Bool = true
  ) -> TestStoreOf<WorkflowsSettingsFeature> {
    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      $settings.withLock { $0 = Self.baseSettings }
      return TestStore(
        initialState: WorkflowsSettingsFeature.State(userDirectory: fixture.userDirectory)
      ) {
        WorkflowsSettingsFeature()
      } withDependencies: {
        $0[WorkflowSettingsClient.self] = fixture.client
        $0[OpenURLClient.self].open = { url in fixture.opened.withValue { $0.append(url) } }
        $0[CLIServiceStatusClient.self].current = { serviceStatus }
        $0[CLIInstallClient.self].installationStatus = { _ in installStatus }
        $0[CLIInstallClient.self].isUsable = { _ in cliUsable }
        $0.continuousClock = clock
      }
    }
  }

  @Test func scopeSelectsOnlyTheRowsOwnedByThatSettingsSurface() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review.yaml")
    let repoDirectory = WorkflowSources.repoDirectory(root: fixture.repoRoot)
    try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
    try Data(Self.review.utf8).write(to: repoDirectory.appending(path: "repo-review.yaml"))
    let catalog = WorkflowSettingsCatalog.build(
      scan: try fixture.scan(), settings: Self.baseSettings)
    var global = WorkflowsSettingsFeature.State(userDirectory: fixture.userDirectory)
    global.catalog = catalog
    var repository = WorkflowsSettingsFeature.State(
      scope: .repository(
        WorkflowSettingsRepositoryContext(
          repositoryID: "repo",
          name: "Repo",
          rootURL: fixture.repoRoot)),
      userDirectory: fixture.userDirectory)
    repository.catalog = catalog

    #expect(global.displayedRows.map(\.scope) == [.user])
    #expect(repository.displayedRows.map(\.scope) == [.repo])
    #expect(repository.workflowDirectory == repoDirectory)
  }

  @Test(.dependencies) func taskLoadsRowsAndCLIStatuses() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review.yaml")
    let store = makeStore(fixture, storage: SettingsTestStorage())

    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }
    let row = try #require(store.state.catalog.user.first)
    #expect(row.settingsKey == "user/review")
    #expect(row.isEnabled)
    #expect(row.launchRoles.first?.candidates.map(\.name) == ["Codex Review"])
    #expect(store.state.cliBlocker == nil)
    #expect(store.state.catalog.repositories.isEmpty)
    // Files are watched too: an in-place edit touches the file's vnode, not the directory's.
    #expect(store.state.watchedPaths.contains(row.url))
    #expect(store.state.watchedPaths.contains(fixture.userDirectory))

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func socketFailureAndMissingCLIBecomeTheBanner() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let store = makeStore(
      fixture, storage: SettingsTestStorage(),
      serviceStatus: .failed(.socketAlreadyOwned, path: "/x"))

    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .failed(.socketAlreadyOwned, path: "/x")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }
    #expect(
      store.state.cliBlocker
        == .socketUnavailable(
          CLIServiceStatus.failed(.socketAlreadyOwned, path: "/x").failureDescription!))

    var missing = WorkflowsSettingsFeature.State(userDirectory: fixture.userDirectory)
    missing.cliInstallStatus = .notInstalled
    missing.cliUsable = false
    missing.cliServiceStatus = .listening(path: "/x")
    #expect(missing.cliBlocker == .cliUnusable(.notInstalled))
    // A dangling link, or a real file that is not an executable, is not a usable `prowl` either.
    missing.cliInstallStatus = .broken(path: "/usr/local/bin/prowl", destination: "/gone")
    #expect(
      missing.cliBlocker
        == .cliUnusable(.broken(path: "/usr/local/bin/prowl", destination: "/gone")))
    missing.cliInstallStatus = .installedDifferentSource(
      path: "/usr/local/bin/prowl", destination: nil)
    #expect(
      missing.cliBlocker
        == .cliUnusable(.installedDifferentSource(path: "/usr/local/bin/prowl", destination: nil)))
    // Another build's executable `prowl` is usable (C2's rule); the socket rules first, and a
    // stopped server is unreachable even though it is not a failure.
    missing.cliInstallStatus = .installedDifferentSource(
      path: "/usr/local/bin/prowl", destination: "/other")
    missing.cliUsable = true
    #expect(missing.cliBlocker == nil)
    missing.cliServiceStatus = .stopped
    #expect(
      missing.cliBlocker == .socketUnavailable(CLIServiceStatus.stopped.unreachableDescription!))

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func disablingWritesTheKeyAndUpdatesTheRow() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review.yaml")
    let storage = SettingsTestStorage()
    let store = makeStore(fixture, storage: storage)
    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }

    var disabled = Self.baseSettings
    disabled.disabledWorkflowIDs = ["user/review"]
    await store.send(.setEnabled(settingsKey: "user/review", isEnabled: false)) {
      $0.catalog = try fixture.expectedCatalog(disabled)
    }
    #expect(store.state.catalog.user.first?.isEnabled == false)
    let stored = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      return settings
    }
    #expect(stored.disabledWorkflowIDs == ["user/review"])
    #expect(stored.agentProfiles == [Self.codexProfile])

    await store.send(.setEnabled(settingsKey: "user/review", isEnabled: true)) {
      $0.catalog = try fixture.expectedCatalog()
    }
    #expect(store.state.catalog.user.first?.isEnabled == true)

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func bindModeAndRememberedBindingPersist() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review.yaml")
    let storage = SettingsTestStorage()
    let store = makeStore(fixture, storage: storage)
    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }
    let key = try #require(store.state.catalog.user.first?.launchRoles.first?.memoryKey)

    var expected = Self.baseSettings
    expected.setWorkflowBindMode(.auto, for: "user/review")
    await store.send(.setBindMode(settingsKey: "user/review", mode: .auto)) { [expected] in
      $0.catalog = try fixture.expectedCatalog(expected)
    }
    #expect(store.state.catalog.user.first?.bindModeOverride == .auto)

    expected.remember(workflowBinding: key, profileID: Self.codexProfile.id)
    await store.send(.setRememberedBinding(key, profileID: Self.codexProfile.id)) { [expected] in
      $0.catalog = try fixture.expectedCatalog(expected)
    }
    #expect(
      store.state.catalog.user.first?.launchRoles.first?.rememberedProfileID == Self.codexProfile.id
    )

    expected.forget(workflowBinding: key)
    await store.send(.setRememberedBinding(key, profileID: nil)) { [expected] in
      $0.catalog = try fixture.expectedCatalog(expected)
    }
    #expect(store.state.catalog.user.first?.launchRoles.first?.rememberedProfileID == nil)

    expected.setWorkflowBindMode(nil, for: "user/review")
    await store.send(.setBindMode(settingsKey: "user/review", mode: nil)) { [expected] in
      $0.catalog = try fixture.expectedCatalog(expected)
    }
    let stored = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.userGlobalSettings) var settings
      return settings
    }
    #expect(stored.workflowBindModeOverrides.isEmpty)
    #expect(stored.workflowBindings.isEmpty)

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func newWorkflowWritesTheStarterOpensItAndReloads() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let store = makeStore(fixture, storage: SettingsTestStorage())
    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }

    let expectedURL = fixture.userDirectory.appending(
      path: "new-workflow.yaml", directoryHint: .notDirectory)
    await store.send(.newWorkflowTapped) {
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }
    await store.receive(
      .delegate(.notice(.workflowCreated(path: expectedURL.path(percentEncoded: false)))))

    let row = try #require(store.state.catalog.user.first)
    #expect(row.workflowID == "new-workflow")
    #expect(row.isValid)
    #expect(fixture.opened.value == [expectedURL])
    #expect(fixture.revealed.value.isEmpty)

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func anOpenDetailBecomesUnavailableWhenItsFileDisappears() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review.yaml")
    let store = makeStore(fixture, storage: SettingsTestStorage())
    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }
    let row = try #require(store.state.catalog.user.first)
    await store.send(.showDetails(rowID: row.id)) {
      $0.path.append($0.detailState(for: row))
    }
    let pathID = try #require(store.state.path.ids.first)
    try FileManager.default.removeItem(at: row.url)

    await store.send(.reload) {
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
      $0.path[id: pathID]?.row = nil
    }

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func confirmedDeletionReturnsToTheRefreshedIndex() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review.yaml")
    let store = makeStore(fixture, storage: SettingsTestStorage())
    store.dependencies[WorkflowSettingsClient.self].trashWorkflow = { url in
      try FileManager.default.removeItem(at: url)
    }
    store.exhaustivity = .off
    await store.send(.task)
    let row = try #require(store.state.catalog.user.first)
    await store.send(.showDetails(rowID: row.id))
    let id = try #require(store.state.path.ids.first)
    await store.send(.path(.element(id: id, action: .deleteTapped)))
    await store.send(.path(.element(id: id, action: .alert(.presented(.confirmDeletion(row.url))))))
    await store.receive(.path(.element(id: id, action: .delegate(.deleted))))
    await store.receive(.reload)
    #expect(store.state.path.isEmpty)
    #expect(store.state.catalog.user.isEmpty)
    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func directoryChangesReloadAfterTheQuietPeriod() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let clock = TestClock()
    let store = makeStore(fixture, storage: SettingsTestStorage(), clock: clock)
    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }

    // Two bursts inside the quiet period coalesce into one reload that sees the new file.
    let continuation = try #require(fixture.watchContinuations.value.last)
    continuation.yield()
    await store.receive(.directoriesChanged)
    await clock.advance(by: .milliseconds(100))
    continuation.yield()
    await store.receive(.directoriesChanged)
    try fixture.write(Self.review, to: "review.yaml")
    await clock.advance(by: WorkflowsSettingsFeature.reloadDebounce)
    await store.receive(.reload) {
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }
    #expect(store.state.catalog.user.map(\.workflowID) == ["review"])

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func teardownStopsTheWatcherAndAPendingReload() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let clock = TestClock()
    let store = makeStore(fixture, storage: SettingsTestStorage(), clock: clock)
    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.scan = try fixture.scan()
      $0.catalog = try fixture.expectedCatalog()
    }
    let continuation = try #require(fixture.watchContinuations.value.last)
    continuation.yield()
    await store.receive(.directoriesChanged)

    // Neither the watcher nor the debounced reload survives the page going away.
    await store.send(.teardown)
    await clock.advance(by: WorkflowsSettingsFeature.reloadDebounce)
    await store.finish()
  }

  @Test(.dependencies) func scanFailureIsReportedAndKeepsTheLastRows() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    fixture.scanError = WorkflowSettingsError(message: "Could not read a workflow folder.")
    let store = makeStore(fixture, storage: SettingsTestStorage())

    await store.send(.task) {
      $0.cliInstallStatus = .installed(path: "/usr/local/bin/prowl")
      $0.cliUsable = true
      $0.cliServiceStatus = .listening(path: "/tmp/cli.sock")
      $0.loadError = "Could not read a workflow folder."
    }
    #expect(store.state.scan == nil)

    fixture.finishWatchers()
    await store.finish()
  }

  @Test(.dependencies) func manageProfilesAndAskAgentDelegateOrPresent() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let store = makeStore(fixture, storage: SettingsTestStorage())

    await store.send(.manageProfilesTapped)
    await store.receive(.delegate(.openProfiles))
    await store.send(.askAgentTapped) {
      $0.isAuthoringPromptPresented = true
    }
    await store.send(.setAuthoringPromptPresented(false)) {
      $0.isAuthoringPromptPresented = false
    }
  }
}
