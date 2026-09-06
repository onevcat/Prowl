import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
import Sharing
import Testing

@testable import supacode

@MainActor
struct AppFeatureSettingsSelectionTests {
  @Test func selectingRepositoryCreatesRepositorySettingsState() async {
    let repository = Repository(
      id: "repo-id",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(repositories: [repository]),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.repository(repository.id)))) {
      $0.settings.selection = .repository(repository.id)
      $0.settings.repositorySettings = RepositorySettingsFeature.State(
        rootURL: repository.rootURL,
        repositoryID: repository.id,
        repositoryKind: repository.kind,
        settings: .default,
        userSettings: .default
      )
    }
  }

  @Test func selectingMissingRepositoryClearsRepositorySettingsState() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(repositories: []),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.repository("missing")))) {
      $0.settings.selection = .repository("missing")
      $0.settings.repositorySettings = nil
    }
  }

  @Test func selectingPlainRepositoryCreatesPlainRepositorySettingsState() async {
    let repository = Repository(
      id: "folder-id",
      rootURL: URL(fileURLWithPath: "/tmp/folder"),
      name: "Folder",
      kind: .plain,
      worktrees: []
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(repositories: [repository]),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.repository(repository.id)))) {
      $0.settings.selection = .repository(repository.id)
      $0.settings.repositorySettings = RepositorySettingsFeature.State(
        rootURL: repository.rootURL,
        repositoryID: repository.id,
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default
      )
    }
  }

  @Test(.dependencies) func selectingRepositorySeedsAppearanceSynchronously() async {
    // Regression: selecting a repo whose appearance is already in
    // @Shared used to construct a State with `.empty` appearance and
    // load asynchronously via .task. The async hop raced with the
    // user's first click, sometimes wiping previously-saved fields.
    // The State must now carry the appearance from frame zero.
    let storage = SettingsTestStorage()
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let savedAppearance = RepositoryAppearance(
      icon: .sfSymbol("hammer.fill"), color: .blue
    )
    let repository = Repository(
      id: "appearance-repo",
      rootURL: URL(fileURLWithPath: "/tmp/appearance-repo"),
      name: "AppearanceRepo",
      worktrees: []
    )

    await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = appearancesURL
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      $appearances.withLock {
        $0[repository.id] = savedAppearance
      }

      let store = TestStore(
        initialState: AppFeature.State(
          repositories: RepositoriesFeature.State(repositories: [repository]),
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.settingsFileStorage = storage.storage
        $0.repositoryAppearancesFileURL = appearancesURL
      }

      await store.send(.settings(.setSelection(.repository(repository.id)))) {
        $0.settings.selection = .repository(repository.id)
        $0.settings.repositorySettings = RepositorySettingsFeature.State(
          rootURL: repository.rootURL,
          repositoryID: repository.id,
          repositoryKind: repository.kind,
          settings: .default,
          userSettings: .default,
          appearance: savedAppearance
        )
      }
    }
  }

  @Test func selectingNonRepositoryClearsRepositorySettingsState() async {
    let repository = Repository(
      id: "repo-id",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [repository]),
      settings: SettingsFeature.State()
    )
    state.settings.selection = .repository(repository.id)
    state.settings.repositorySettings = RepositorySettingsFeature.State(
      rootURL: repository.rootURL,
      repositoryKind: repository.kind,
      settings: .default,
      userSettings: .default
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.general))) {
      $0.settings.selection = .general
      $0.settings.repositorySettings = nil
    }
  }

  @Test func showingShortcutNavigatesThroughAppSettingsSelection() async {
    var state = AppFeature.State(settings: SettingsFeature.State())
    state.settings.selection = .notifications
    let commandID = AppShortcuts.CommandID.toggleAgentIsland
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.settings(.showShortcutButtonTapped(commandID: commandID))) {
      $0.settings.shortcutNavigationTargetCommandID = commandID
    }
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .shortcuts
    }
  }

  @Test(.dependencies) func islandSettingsOpensDisplayAndCollapsesRosterWithoutFocusingAPane() async {
    let shown = LockIsolated(false)
    let surfaced = LockIsolated(false)
    var state = AppFeature.State(settings: SettingsFeature.State())
    state.repositories.activeAgents.isIslandRosterExpanded = true
    state.repositories.activeAgents.islandNavigation.selectedEntryID = UUID()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.settingsWindowClient.show = { shown.setValue(true) }
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.setValue(true)
        return true
      }
    }

    await store.send(.repositories(.activeAgents(.islandSettingsTapped))) {
      $0.repositories.activeAgents.isIslandRosterExpanded = false
      $0.repositories.activeAgents.islandNavigation = .init()
    }
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .agentDisplay
    }
    await store.finish()
    #expect(shown.value)
    #expect(surfaced.value)
  }

  @Test(.dependencies) func openAgentProfilesSettingsSelectsProfiles() async {
    let shown = LockIsolated(false)
    var state = AppFeature.State(settings: SettingsFeature.State())
    state.settings.selection = .commandLineTool
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.settingsWindowClient.show = {
        shown.withValue { $0 = true }
      }
    }

    await store.send(.openAgentProfilesSettings)
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .profiles
      $0.settings.agentProfiles = .init()
    }
    await store.finish()

    #expect(shown.value)
  }

  @Test(.dependencies) func settingsWorkflowStartKeepsItsWindowAndReturnsToItsDetail() async throws {
    let root = URL(filePath: "/tmp/settings-run")
    let worktree = Worktree(
      id: "settings-run", name: "main", detail: "", workingDirectory: root, repositoryRootURL: root)
    let repository = Repository(id: "repo", rootURL: root, name: "Repo", worktrees: [worktree])
    let definition = try #require(WorkflowDocumentParser.parse(WorkflowStartContextTests.worktreeOnly).definition)
    let context = WorkflowStartContext(
      item: WorkflowStartCatalogItem(
        key: "user/worktree-only", scope: .user, fileURL: root.appending(path: "flow.yaml"),
        workflowID: definition.id, name: definition.name, workflowDescription: nil,
        icon: nil, validationFailure: nil),
      definition: definition, worktreeID: worktree.id, worktreeName: worktree.name,
      source: nil, launchRoles: [], pickRoles: [], cliInstalled: true, bindModeOverride: nil)
    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [repository]),
      settings: SettingsFeature.State())
    state.settings.selection = .workflows
    state.settings.workflows = .init()
    let surfaced = LockIsolated(false)
    let focused = LockIsolated(false)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0[WorkflowStartClient.self].context = { _, _, _ in context }
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.setValue(true)
        return true
      }
      $0.terminalClient.send = { _ in focused.setValue(true) }
    }
    store.exhaustivity = .off
    await store.send(
      .settings(
        .workflows(
          .delegate(
            .runWorkflow(
              workflowKey: context.item.key, worktreeID: worktree.id, forceSheet: true)))))
    #expect(store.state.workflowStart?.context == context)
    #expect(store.state.workflowStartFromSettings)
    #expect(!surfaced.value)
    await store.send(.workflowStart(.presented(.cancelTapped)))
    await store.receive(\.workflowStart.presented.delegate)
    await store.finish()
    #expect(store.state.workflowStart == nil)
    #expect(!store.state.workflowStartFromSettings)
    #expect(store.state.settings.selection == .workflows)
    #expect(!focused.value)
  }

  @Test(.dependencies) func workflowDetailsDeepLinkLoadsAndPushesTheExactFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "workflow-deep-link-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "review.yaml")
    let yaml = """
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
          text: "Review."
      """
    try Data(yaml.utf8).write(to: url)
    let file = WorkflowDiscovery.parse(
      yaml,
      url: url,
      scope: .user,
      context: WorkflowValidationContext(scope: .user))
    let entry = WorkflowCatalogEntry(file: file, shadowed: false)
    let item = try #require(
      WorkflowStartCatalogItem.make(
        entry: entry,
        disabledWorkflowIDs: [],
        repositoryRootPath: nil))
    let scan = WorkflowSettingsScan(
      bundleDirectory: nil,
      userDirectory: directory,
      entries: [entry],
      repositories: [])
    let shown = LockIsolated(false)
    let store = TestStore(initialState: AppFeature.State(settings: SettingsFeature.State())) {
      AppFeature()
    } withDependencies: {
      $0[WorkflowSettingsClient.self].scan = { _ in scan }
      $0.settingsWindowClient.show = { shown.withValue { $0 = true } }
    }
    store.exhaustivity = .off

    await store.send(.openWorkflowDetails(item, worktreeID: "unused"))
    await store.receive(\.settings.setSelection)
    await store.receive(\.settings.workflows.task)
    await store.receive(\.settings.workflows.showDetails)
    await store.finish()

    #expect(store.state.settings.selection == .workflows)
    #expect(store.state.settings.workflows?.path.first?.row?.url == url)
    #expect(shown.value)
  }

  @Test(.dependencies) func repositoryWorkflowDetailsDeepLinkUsesRepositorySettings() async throws {
    let rootURL = URL(fileURLWithPath: "/tmp/repository-workflow-deep-link")
    let workflowURL = WorkflowSources.repoDirectory(root: rootURL).appending(path: "review.yaml")
    let yaml = """
      schema: prowl.workflow/v1
      id: review
      name: Repository Review
      roles:
        author:
          source: current
      steps:
        - id: ask
          message: author
          text: "Review."
      """
    let file = WorkflowDiscovery.parse(
      yaml,
      url: workflowURL,
      scope: .repo,
      context: WorkflowValidationContext(scope: .repo))
    let entry = WorkflowCatalogEntry(file: file, shadowed: false)
    let item = try #require(
      WorkflowStartCatalogItem.make(
        entry: entry,
        disabledWorkflowIDs: [],
        repositoryRootPath: rootURL.path(percentEncoded: false)))
    let worktree = Worktree(
      id: "wt-1",
      name: "feature",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL)
    let repository = Repository(
      id: "repo-id",
      rootURL: rootURL,
      name: "Repo",
      worktrees: [worktree])
    let scan = WorkflowSettingsScan(
      bundleDirectory: nil,
      userDirectory: URL(filePath: "/tmp/user-workflows"),
      entries: [],
      repositories: [
        WorkflowSettingsRepositoryScan(
          repositoryID: repository.id,
          name: repository.name,
          rootPath: rootURL.path(percentEncoded: false),
          directory: WorkflowSources.repoDirectory(root: rootURL),
          entries: [entry])
      ])
    let shown = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(repositories: [repository]),
        settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0[WorkflowSettingsClient.self].scan = { _ in scan }
      $0.settingsWindowClient.show = { shown.withValue { $0 = true } }
    }
    store.exhaustivity = .off

    await store.send(.openWorkflowDetails(item, worktreeID: worktree.id))
    await store.receive(\.settings.setSelection)
    await store.receive(\.settings.repositorySettings.workflowsAppeared)
    await store.receive(\.settings.repositorySettings.workflows.task)
    await store.receive(\.settings.repositorySettings.workflows.showDetails)
    await store.finish()

    #expect(store.state.settings.selection == .repository(repository.id))
    #expect(store.state.settings.repositorySettings?.workflows.path.first?.row?.url == workflowURL)
    #expect(shown.value)
  }

  @Test(arguments: [SettingsSection.general, .agentDisplay, .commandLineTool])
  func selectingAnotherSectionClearsAgentProfileEditorState(section: SettingsSection) async {
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    var state = AppFeature.State(settings: SettingsFeature.State())
    state.settings.selection = .profiles
    var agentProfiles = AgentProfilesFeature.State()
    agentProfiles.settings = UserGlobalSettings(customCommands: [], agentProfiles: [profile])
    agentProfiles.path.append(AgentProfileEditorFeature.State(profile: profile))
    state.settings.agentProfiles = agentProfiles
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(section))) {
      $0.settings.selection = section
      $0.settings.agentProfiles = nil
      if section == .commandLineTool {
        $0.settings.agentSkills = .init()
      }
    }
  }

  @Test func selectingCommandLineToolInitialisesAgentSkillsState() async {
    let store = TestStore(initialState: AppFeature.State(settings: SettingsFeature.State())) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.commandLineTool))) {
      $0.settings.selection = .commandLineTool
      $0.settings.agentSkills = .init()
    }
  }

  @Test(arguments: [SettingsSection.general, .agentDisplay, .profiles])
  func selectingAnotherSectionClearsAgentSkillsState(section: SettingsSection) async {
    var state = AppFeature.State(settings: SettingsFeature.State())
    state.settings.selection = .commandLineTool
    state.settings.agentSkills = .init()
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(section))) {
      $0.settings.selection = section
      $0.settings.agentSkills = nil
      if section == .profiles {
        $0.settings.agentProfiles = .init()
      }
    }
  }
}
