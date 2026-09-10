import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowSettingsDetailFeatureTests {
  private static let yaml = """
    schema: prowl.workflow/v1
    id: review
    name: Review
    icon: magnifyingglass
    roles:
      author:
        source: current
    steps:
      - id: ask
        message: author
        prompt: "Review this change."
    """

  private func row(scope: WorkflowScope = .user) throws -> WorkflowSettingsRow {
    let url = URL(filePath: "/tmp/review.yaml")
    let file = WorkflowDiscovery.parse(
      Self.yaml,
      url: url,
      scope: scope,
      context: WorkflowValidationContext(scope: scope))
    let scan = WorkflowSettingsScan(
      bundleDirectory: nil,
      userDirectory: URL(filePath: "/tmp"),
      entries: [WorkflowCatalogEntry(file: file, shadowed: false)],
      repositories: [])
    let catalog = WorkflowSettingsCatalog.build(
      scan: scan, settings: UserGlobalSettings(customCommands: [], agentProfiles: []))
    return try #require((catalog.user + catalog.bundle).first)
  }

  @Test func removedBundleFilesCanBeSelectedForReview() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.yaml.write(to: directory.appending(path: "workflow.yaml"), atomically: true, encoding: .utf8)
    let snapshot = try WorkflowBundleSnapshot.read(directory)
    var state = WorkflowSettingsDetailFeature.State(row: try row(), runTargets: [])
    state.bundleReview = WorkflowBundleReview(
      snapshot: snapshot, scripts: [],
      changes: [.init(path: "removed.py", kind: .removed)], approved: false)
    let store = TestStore(initialState: state) { WorkflowSettingsDetailFeature() }
    await store.send(.reviewFileSelected("removed.py")) { $0.bundleReview?.selectedFile = "removed.py" }
    #expect(store.state.bundleReview?.preview == "This file was removed from the bundle.")
  }

  @Test func deletionRequiresConfirmationAndUsesTheExactFile() async throws {
    let row = try row()
    let trashed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: WorkflowSettingsDetailFeature.State(row: row, runTargets: [])) {
      WorkflowSettingsDetailFeature()
    } withDependencies: {
      $0[WorkflowSettingsClient.self].trashWorkflow = { url in trashed.withValue { $0.append(url) } }
    }
    store.exhaustivity = .off

    await store.send(.deleteTapped)
    #expect(store.state.alert != nil)
    #expect(trashed.value.isEmpty)
    await store.send(.alert(.dismiss))
    #expect(trashed.value.isEmpty)
    await store.send(.deleteTapped)
    await store.send(.alert(.presented(.confirmDeletion(row.url))))
    await store.receive(.delegate(.deleted))
    #expect(trashed.value == [row.url])
  }

  @Test func deletionFailureKeepsTheDetailAndExplainsTheError() async throws {
    let row = try row()
    let store = TestStore(initialState: WorkflowSettingsDetailFeature.State(row: row, runTargets: [])) {
      WorkflowSettingsDetailFeature()
    } withDependencies: {
      $0[WorkflowSettingsClient.self].trashWorkflow = { _ in
        throw WorkflowSettingsError(message: "The file is read-only.")
      }
    }
    store.exhaustivity = .off
    await store.send(.deleteTapped)
    await store.send(.alert(.presented(.confirmDeletion(row.url))))
    #expect(store.state.row == row)
    #expect(store.state.alert?.title == TextState("Could Not Delete Workflow"))
  }

  @Test func builtInAndUnavailableWorkflowsCannotBeDeleted() async throws {
    let row = try row(scope: .bundle)
    let store = TestStore(initialState: WorkflowSettingsDetailFeature.State(row: row, runTargets: [])) {
      WorkflowSettingsDetailFeature()
    }
    await store.send(.deleteTapped)
  }

  @Test func repositoryScopeFiltersRunTargetsWithoutChangingGlobalOrder() {
    let targets = [
      WorkflowSettingsRunTarget(
        id: "a", name: "main", repositoryName: "Alpha", rootPath: "/tmp/alpha", isPreferred: false),
      WorkflowSettingsRunTarget(
        id: "b", name: "feature", repositoryName: "Beta", rootPath: "/tmp/beta", isPreferred: true),
    ]
    let repository = WorkflowSettingsRepositoryContext(
      repositoryID: "beta",
      name: "Beta",
      rootURL: URL(filePath: "/tmp/beta"))

    #expect(WorkflowSettingsRunTarget.visible(targets, in: .global).map(\.id) == ["a", "b"])
    #expect(
      WorkflowSettingsRunTarget.visible(targets, in: .repository(repository)).map(\.id) == ["b"])
  }

  @Test func settingsAndRunActionsDelegateWithExplicitIdentity() async throws {
    let row = try row()
    let target = WorkflowSettingsRunTarget(
      id: "wt-1",
      name: "feature",
      repositoryName: "Prowl",
      rootPath: "/tmp/Prowl",
      isPreferred: true)
    let store = TestStore(
      initialState: WorkflowSettingsDetailFeature.State(row: row, runTargets: [target])
    ) {
      WorkflowSettingsDetailFeature()
    }

    await store.send(.enabledChanged(false))
    await store.receive(.delegate(.setEnabled(settingsKey: "user/review", enabled: false)))
    await store.send(.runSetupChanged(.ask))
    await store.receive(.delegate(.setRunSetup(settingsKey: "user/review", mode: .ask)))
    await store.send(.runTapped(worktreeID: "wt-1", forceSheet: true))
    await store.receive(
      .delegate(.runWorkflow(workflowKey: "user/review", worktreeID: "wt-1", forceSheet: true)))
  }

  @Test func aDeletedFileLeavesAnInertUnavailableRoute() async throws {
    let row = try row()
    var state = WorkflowSettingsDetailFeature.State(row: row, runTargets: [])
    state.row = nil
    let store = TestStore(initialState: state) {
      WorkflowSettingsDetailFeature()
    }

    await store.send(.openWorkflowTapped)
    await store.send(.revealInFinderTapped)
    await store.send(.deleteTapped)
    await store.send(.runTapped(worktreeID: "wt-1", forceSheet: false))
  }

  @Test func sourceActionsUseTheSharedOpenAndRevealBoundaries() async throws {
    let row = try row()
    let opened = LockIsolated<[URL]>([])
    let revealed = LockIsolated<[URL]>([])
    let store = TestStore(
      initialState: WorkflowSettingsDetailFeature.State(row: row, runTargets: [])
    ) {
      WorkflowSettingsDetailFeature()
    } withDependencies: {
      $0[OpenURLClient.self].open = { url in opened.withValue { $0.append(url) } }
      $0[WorkflowSettingsClient.self].reveal = { url in revealed.withValue { $0.append(url) } }
    }

    await store.send(.openWorkflowTapped)
    await store.send(.revealInFinderTapped)

    #expect(opened.value == [row.url.appending(path: "workflow.yaml")])
    #expect(revealed.value == [row.url])
  }
}
