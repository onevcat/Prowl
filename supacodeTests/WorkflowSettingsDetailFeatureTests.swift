import ComposableArchitecture
import Foundation
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
        text: "Review this change."
    """

  private func row() throws -> WorkflowSettingsRow {
    let url = URL(filePath: "/tmp/review.yaml")
    let file = WorkflowDiscovery.parse(
      Self.yaml,
      url: url,
      scope: .user,
      context: WorkflowValidationContext(scope: .user))
    let scan = WorkflowSettingsScan(
      bundleDirectory: nil,
      userDirectory: URL(filePath: "/tmp"),
      entries: [WorkflowCatalogEntry(file: file, shadowed: false)],
      repositories: [])
    return try #require(
      WorkflowSettingsCatalog.build(
        scan: scan,
        settings: UserGlobalSettings(customCommands: [], agentProfiles: [])
      ).user.first)
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

    #expect(opened.value == [row.url])
    #expect(revealed.value == [row.url])
  }
}
