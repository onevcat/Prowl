import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorkspaceEditorFeatureTests {
  private let rootURL = URL(fileURLWithPath: "/tmp/workspaces/checkout-flow", isDirectory: true)

  private var appEntry: ProjectWorkspaceRepositoryEntry {
    ProjectWorkspaceRepositoryEntry(
      id: "app",
      name: "App",
      role: "macOS app",
      path: "app",
      sourceKind: .existingPath,
      sourceLocation: "/tmp/source/app",
      branchName: "codex/checkout",
      baseRef: "main"
    )
  }

  private var apiEntry: ProjectWorkspaceRepositoryEntry {
    ProjectWorkspaceRepositoryEntry(
      id: "api",
      name: "API",
      path: "api",
      sourceKind: .remote,
      sourceLocation: "git@github.com:onevcat/api.git",
      baseRef: "origin/main"
    )
  }

  private var workspace: ProjectWorkspace {
    ProjectWorkspace(
      id: rootURL.path(percentEncoded: false),
      title: "Checkout Flow",
      description: "Ship the flow",
      taskLinks: ["https://example.com/issues/1", "PROWL-7"],
      repositories: [appEntry, apiEntry]
    )
  }

  private var sharedCandidate: ProjectWorkspaceCreationRepository {
    ProjectWorkspaceCreationRepository(
      id: "/tmp/source/shared",
      name: "Shared",
      rootURL: URL(fileURLWithPath: "/tmp/source/shared")
    )
  }

  private func makeEditState() -> WorkspaceEditorFeature.State {
    WorkspaceEditorFeature.State(
      editing: workspace,
      rootURL: rootURL,
      repositoryID: "/tmp/workspaces/checkout-flow",
      openedRepositoryCandidates: [sharedCandidate]
    )
  }

  @Test func editModePopulatesFromWorkspaceMetadata() {
    let state = makeEditState()

    #expect(state.mode == .edit(repositoryID: "/tmp/workspaces/checkout-flow"))
    #expect(state.title == "Checkout Flow")
    #expect(state.description == "Ship the flow")
    #expect(state.taskLinksText == "https://example.com/issues/1\nPROWL-7")
    #expect(state.taskLinks == ["https://example.com/issues/1", "PROWL-7"])
    #expect(state.rootPath == "/tmp/workspaces/checkout-flow")
    #expect(state.isRootPathDirty)
    #expect(state.existingRepositories.map(\.id) == ["app", "api"])
    #expect(state.existingRepositories[id: "app"]?.role == "macOS app")
    #expect(state.existingRepositories[id: "app"]?.offersBranchDeletion == true)
    #expect(state.existingRepositories[id: "api"]?.offersBranchDeletion == false)
    #expect(state.repositories.isEmpty)
    #expect(state.remainingRepositoryCount == 2)
    #expect(state.memberEditor == nil)
  }

  @Test func titleChangeInEditModeKeepsRootPath() async {
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    }

    await store.send(.titleChanged("Renamed")) {
      $0.title = "Renamed"
    }
    #expect(store.state.rootPath == "/tmp/workspaces/checkout-flow")
  }

  @Test func taskLinksTextParsesOneLinkPerLineAndDropsBlanks() async {
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    }

    await store.send(.taskLinksTextChanged("  https://example.com/issues/2 \n\n PROWL-42\n   ")) {
      $0.taskLinksText = "  https://example.com/issues/2 \n\n PROWL-42\n   "
    }
    #expect(store.state.taskLinks == ["https://example.com/issues/2", "PROWL-42"])
  }

  @Test func addRepositoryPresentsTheMemberEditorWithUnusedCandidates() async {
    var state = makeEditState()
    state.repositories = [sharedCandidate]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    // The only candidate is already added, so the picker offers nothing.
    await store.send(.addRepositoryButtonTapped) {
      $0.memberEditor = .add(openedCandidates: [])
    }
  }

  @Test func memberEditorCommitAddsANewRowAndReplacesAReEditedOne() async {
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    }

    await store.send(.addRepositoryButtonTapped) {
      $0.memberEditor = .add(openedCandidates: [self.sharedCandidate])
    }
    await store.send(.memberEditor(.presented(.delegate(.commitAdded(sharedCandidate))))) {
      $0.repositories = [self.sharedCandidate]
      $0.memberEditor = nil
    }
    #expect(store.state.orderedMemberKeys == [.existing("app"), .existing("api"), .added("/tmp/source/shared")])

    var renamed = sharedCandidate
    renamed.name = "Shared Kit"
    renamed.role = "library"
    await store.send(.editMember(.added("/tmp/source/shared"))) {
      $0.memberEditor = .editAdded(self.sharedCandidate)
    }
    await store.send(.memberEditor(.presented(.delegate(.commitAdded(renamed))))) {
      $0.repositories = [renamed]
      $0.memberEditor = nil
    }
    await store.send(.editMember(.added("/tmp/source/shared"))) {
      $0.memberEditor = .editAdded(renamed)
    }
    await store.send(.memberEditor(.presented(.delegate(.removeAdded("/tmp/source/shared"))))) {
      $0.repositories = []
      $0.memberEditor = nil
    }
  }

  @Test func editingAnExistingMemberRoundTripsNameRoleAndRemoval() async {
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    }
    var app = WorkspaceEditorExistingRepository(entry: appEntry)
    app.name = "Mac App"
    app.role = ""
    app.removal = .init(deleteFiles: true, deleteBranch: true)

    await store.send(.editMember(.existing("app"))) {
      $0.memberEditor = .editExisting(WorkspaceEditorExistingRepository(entry: self.appEntry))
    }
    await store.send(.memberEditor(.presented(.delegate(.commitExisting(app))))) {
      $0.existingRepositories[id: "app"] = app
      $0.memberEditor = nil
    }
    #expect(store.state.remainingRepositoryCount == 1)
    await store.send(.undoRemoval("app")) {
      $0.existingRepositories[id: "app"]?.removal = nil
    }
    var reopened = app
    reopened.removal = nil
    await store.send(.editMember(.existing("app"))) {
      $0.memberEditor = .editExisting(reopened)
    }
    await store.send(.memberEditor(.presented(.delegate(.cancel)))) {
      $0.memberEditor = nil
    }
  }

  @Test func removeMemberMarksExistingAndDropsAdded() async {
    var state = makeEditState()
    state.repositories = [sharedCandidate]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    await store.send(.removeMember(.existing("api"))) {
      $0.existingRepositories[id: "api"]?.removal = .init()
    }
    await store.send(.removeMember(.added("/tmp/source/shared"))) {
      $0.repositories = []
    }
    await store.send(.removeMember(.existing("missing")))
    #expect(store.state.hasPendingRemovals)
    #expect(store.state.remainingRepositoryCount == 1)
  }

  @Test func membersCanBeReorderedAcrossExistingAndAddedRows() async {
    var state = makeEditState()
    state.repositories = [sharedCandidate]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    #expect(store.state.orderedMemberKeys == [.existing("app"), .existing("api"), .added("/tmp/source/shared")])
    await store.send(.memberMovedUp(.existing("app")))
    await store.send(.memberMovedUp(.added("/tmp/source/shared"))) {
      $0.memberOrder = [.existing("app"), .added("/tmp/source/shared"), .existing("api")]
    }
    await store.send(.memberMovedUp(.added("/tmp/source/shared"))) {
      $0.memberOrder = [.added("/tmp/source/shared"), .existing("app"), .existing("api")]
    }
    await store.send(.memberMovedDown(.existing("api")))
    await store.send(.removeMember(.added("/tmp/source/shared"))) {
      $0.repositories = []
    }
    #expect(store.state.orderedMemberKeys == [.existing("app"), .existing("api")])
  }

  @Test func submitRefusesToRemoveTheLastMember() async {
    var state = makeEditState()
    state.existingRepositories[id: "app"]?.removal = .init()
    state.existingRepositories[id: "api"]?.removal = .init()
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    await store.send(.submitButtonTapped) {
      $0.validationMessage = "Add at least one repository."
      $0.validationTarget = .repositories
    }
  }

  @Test func submitInEditModeBuildsUpdateRequestInRowOrder() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var state = makeEditState()
    state.title = "  Checkout Flow v2 "
    state.description = " Ship it \n"
    state.taskLinksText = "  https://example.com/issues/2 \n\n"
    state.existingRepositories[id: "app"]?.name = " Mac App "
    state.existingRepositories[id: "app"]?.role = ""
    state.existingRepositories[id: "api"]?.removal = .init(deleteFiles: true, deleteBranch: false)
    var shared = sharedCandidate
    shared.role = " library "
    state.repositories = [shared]
    state.memberOrder = [.added("/tmp/source/shared"), .existing("app"), .existing("api")]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    } withDependencies: {
      $0.date.now = now
    }

    var renamedApp = appEntry
    renamedApp.name = "Mac App"
    renamedApp.role = nil
    await store.send(.submitButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          .update(
            ProjectWorkspaceUpdateRequest(
              rootURL: rootURL,
              title: "Checkout Flow v2",
              description: "Ship it",
              taskLinks: ["https://example.com/issues/2"],
              members: [
                .added(
                  ProjectWorkspaceRepositoryPlan(
                    id: "/tmp/source/shared",
                    name: "Shared",
                    role: "library",
                    path: nil,
                    sourceKind: .existingPath,
                    sourceLocation: "/tmp/source/shared",
                    checkout: .link
                  )),
                .existing(renamedApp),
              ],
              removals: [
                ProjectWorkspaceRepositoryRemoval(entry: apiEntry, deleteFiles: true, deleteBranch: false)
              ],
              updatedAt: now
            )
          )
        )
      )
    )
  }

  @Test func submitInCreateModeCarriesDescriptionLinksRoleAndOrder() async {
    var repoA = ProjectWorkspaceCreationRepository(
      id: "/tmp/repo-a", name: "Repo A", rootURL: URL(fileURLWithPath: "/tmp/repo-a"))
    repoA.role = "app"
    let repoB = ProjectWorkspaceCreationRepository(
      id: "/tmp/repo-b", name: "Repo B", rootURL: URL(fileURLWithPath: "/tmp/repo-b"))
    var state = WorkspaceEditorFeature.State(
      repositories: [repoA, repoB],
      title: " Multi Repo ",
      rootPath: " /tmp/multi-repo-workspace "
    )
    state.description = "Just two"
    state.taskLinksText = "PROWL-1"
    state.memberOrder = [.added("/tmp/repo-b"), .added("/tmp/repo-a")]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    await store.send(.submitButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          .create(
            ProjectWorkspaceCreationDraft(
              title: "Multi Repo",
              description: "Just two",
              taskLinks: ["PROWL-1"],
              rootURL: URL(filePath: "/tmp/multi-repo-workspace", directoryHint: .isDirectory),
              repositories: [
                ProjectWorkspaceRepositoryPlan(
                  id: "/tmp/repo-b",
                  name: "Repo B",
                  path: nil,
                  sourceKind: .existingPath,
                  sourceLocation: "/tmp/repo-b",
                  checkout: .link
                ),
                ProjectWorkspaceRepositoryPlan(
                  id: "/tmp/repo-a",
                  name: "Repo A",
                  role: "app",
                  path: nil,
                  sourceKind: .existingPath,
                  sourceLocation: "/tmp/repo-a",
                  checkout: .link
                ),
              ]
            )
          )
        )
      )
    )
  }

  @Test func submitReportsAStaleInvalidRow() async {
    var state = makeEditState()
    state.repositories = [
      ProjectWorkspaceCreationRepository(
        id: "remote",
        name: "Remote",
        sourceKind: .remote,
        sourceLocation: "git@github.com:onevcat/x.git",
        checkoutMode: .useExistingRef
      )
    ]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    await store.send(.submitButtonTapped) {
      $0.validationMessage = "Choose an existing branch for Remote."
      $0.validationTarget = .repositories
    }
  }

  @Test func createModeFolderFollowsTitleUntilChosen() async {
    let store = TestStore(
      initialState: WorkspaceEditorFeature.State(repositories: [], title: "Workspace", rootPath: "/tmp/x")
    ) {
      WorkspaceEditorFeature()
    }
    store.exhaustivity = .off

    await store.send(.titleChanged("Checkout Flow")) {
      $0.title = "Checkout Flow"
      $0.rootPath = ProjectWorkspace.workspaceRootPath(folderName: "Checkout-Flow", suffix: nil)
    }
    await store.receive(\.automaticRootPathResolved)
    await store.send(.rootPathChosen("/tmp/custom")) {
      $0.rootPath = "/tmp/custom"
      $0.isRootPathDirty = true
    }
    await store.send(.titleChanged("Other")) {
      $0.title = "Other"
    }
    #expect(store.state.rootPath == "/tmp/custom")
  }
}
