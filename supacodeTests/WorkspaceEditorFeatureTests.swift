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
      taskLinks: ["https://example.com/issues/1"],
      repositories: [appEntry, apiEntry]
    )
  }

  private func makeEditState() -> WorkspaceEditorFeature.State {
    WorkspaceEditorFeature.State(
      editing: workspace,
      rootURL: rootURL,
      repositoryID: "/tmp/workspaces/checkout-flow",
      openedRepositoryCandidates: [
        ProjectWorkspaceCreationRepository(
          id: "/tmp/source/shared",
          name: "Shared",
          rootURL: URL(fileURLWithPath: "/tmp/source/shared")
        )
      ]
    )
  }

  @Test func editModePopulatesFromWorkspaceMetadata() {
    let state = makeEditState()

    #expect(state.mode == .edit(repositoryID: "/tmp/workspaces/checkout-flow"))
    #expect(state.title == "Checkout Flow")
    #expect(state.description == "Ship the flow")
    #expect(state.taskLinks.map(\.value) == ["https://example.com/issues/1"])
    #expect(state.taskLinks.map(\.id) == ["task-link-0"])
    #expect(state.rootPath == "/tmp/workspaces/checkout-flow")
    #expect(state.isRootPathDirty)
    #expect(state.existingRepositories.map(\.id) == ["app", "api"])
    #expect(state.existingRepositories[id: "app"]?.role == "macOS app")
    #expect(state.existingRepositories[id: "api"]?.role == "")
    #expect(state.existingRepositories[id: "app"]?.offersBranchDeletion == true)
    #expect(state.existingRepositories[id: "api"]?.offersBranchDeletion == false)
    #expect(state.repositories.isEmpty)
    #expect(state.remainingRepositoryCount == 2)
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

  @Test func taskLinksCanBeAddedEditedAndRemoved() async {
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.addTaskLinkButtonTapped) {
      $0.taskLinks.append(WorkspaceTaskLinkDraft(id: UUID(0).uuidString, value: ""))
    }
    await store.send(.taskLinkChanged(UUID(0).uuidString, "PROWL-42")) {
      $0.taskLinks[id: UUID(0).uuidString]?.value = "PROWL-42"
    }
    await store.send(.removeTaskLink("task-link-0")) {
      $0.taskLinks.remove(id: "task-link-0")
    }
    #expect(store.state.taskLinks.map(\.value) == ["PROWL-42"])
  }

  @Test func removalMarkingGatesDeleteFlagsAndCanBeUndone() async {
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    }

    // Flags on an unmarked member are ignored.
    await store.send(.existingRepositoryDeleteFilesChanged("app", true))
    await store.send(.existingRepositoryMarkedForRemoval("app")) {
      $0.existingRepositories[id: "app"]?.removal = .init()
    }
    #expect(store.state.remainingRepositoryCount == 1)
    #expect(store.state.hasPendingRemovals)
    // Branch deletion requires file deletion.
    await store.send(.existingRepositoryDeleteBranchChanged("app", true))
    await store.send(.existingRepositoryDeleteFilesChanged("app", true)) {
      $0.existingRepositories[id: "app"]?.removal?.deleteFiles = true
    }
    await store.send(.existingRepositoryDeleteBranchChanged("app", true)) {
      $0.existingRepositories[id: "app"]?.removal?.deleteBranch = true
    }
    // Turning file deletion off clears the branch choice.
    await store.send(.existingRepositoryDeleteFilesChanged("app", false)) {
      $0.existingRepositories[id: "app"]?.removal = .init(deleteFiles: false, deleteBranch: false)
    }
    await store.send(.existingRepositoryRemovalUndone("app")) {
      $0.existingRepositories[id: "app"]?.removal = nil
    }
    // A clone has no branch to delete.
    await store.send(.existingRepositoryMarkedForRemoval("api")) {
      $0.existingRepositories[id: "api"]?.removal = .init()
    }
    await store.send(.existingRepositoryDeleteFilesChanged("api", true)) {
      $0.existingRepositories[id: "api"]?.removal?.deleteFiles = true
    }
    await store.send(.existingRepositoryDeleteBranchChanged("api", true))
  }

  @Test func existingMembersCanBeReordered() async {
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    }

    #expect(store.state.orderedMemberKeys == [.existing("app"), .existing("api")])
    await store.send(.memberMovedUp(.existing("app")))
    await store.send(.memberMovedDown(.existing("app"))) {
      $0.memberOrder = [.existing("api"), .existing("app")]
    }
    await store.send(.memberMovedDown(.existing("app")))
    await store.send(.memberMovedUp(.existing("app"))) {
      $0.memberOrder = [.existing("app"), .existing("api")]
    }
    #expect(store.state.orderedMembers.map(\.id) == [.existing("app"), .existing("api")])
  }

  @Test func addedMemberCanMoveBeforeExistingMembersAndSubmitKeepsThatOrder() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let shared = ProjectWorkspaceCreationRepository(
      id: "/tmp/source/shared",
      name: "Shared",
      rootURL: URL(fileURLWithPath: "/tmp/source/shared")
    )
    let store = TestStore(initialState: makeEditState()) {
      WorkspaceEditorFeature()
    } withDependencies: {
      $0.date.now = now
    }

    await store.send(.addOpenedRepository("/tmp/source/shared")) {
      $0.repositories = [shared]
    }
    await store.receive(\.delegate.baseRefSourceChanged)
    // Added rows append after existing members until they are moved.
    #expect(
      store.state.orderedMemberKeys == [.existing("app"), .existing("api"), .added("/tmp/source/shared")])
    await store.send(.memberMovedUp(.added("/tmp/source/shared"))) {
      $0.memberOrder = [.existing("app"), .added("/tmp/source/shared"), .existing("api")]
    }
    await store.send(.memberMovedUp(.added("/tmp/source/shared"))) {
      $0.memberOrder = [.added("/tmp/source/shared"), .existing("app"), .existing("api")]
    }
    await store.send(.memberMovedUp(.added("/tmp/source/shared")))

    await store.send(.submitButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          .update(
            ProjectWorkspaceUpdateRequest(
              rootURL: rootURL,
              title: "Checkout Flow",
              description: "Ship the flow",
              taskLinks: ["https://example.com/issues/1"],
              members: [
                .added(
                  ProjectWorkspaceRepositoryPlan(
                    id: "/tmp/source/shared",
                    name: "Shared",
                    path: nil,
                    sourceKind: .existingPath,
                    sourceLocation: "/tmp/source/shared",
                    checkout: .link
                  )),
                .existing(appEntry),
                .existing(apiEntry),
              ],
              updatedAt: now
            )
          )
        )
      )
    )
  }

  @Test func removedRowsDropOutOfTheOrder() async {
    var state = makeEditState()
    state.repositories = [
      ProjectWorkspaceCreationRepository(
        id: "/tmp/source/shared", name: "Shared", rootURL: URL(fileURLWithPath: "/tmp/source/shared"))
    ]
    state.memberOrder = [.added("/tmp/source/shared"), .existing("app"), .existing("api")]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    await store.send(.removeRepository("/tmp/source/shared")) {
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
      $0.validationTarget = nil
      $0.validationRequestID = 1
    }
  }

  @Test func submitInEditModeBuildsUpdateRequest() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var state = makeEditState()
    state.title = "  Checkout Flow v2 "
    state.description = " Ship it \n"
    state.taskLinks = [
      WorkspaceTaskLinkDraft(id: "a", value: "  https://example.com/issues/2 "),
      WorkspaceTaskLinkDraft(id: "b", value: "   "),
    ]
    state.existingRepositories[id: "app"]?.name = " Mac App "
    state.existingRepositories[id: "app"]?.role = ""
    state.existingRepositories[id: "api"]?.removal = .init(deleteFiles: true, deleteBranch: false)
    state.repositories = [
      {
        var repository = ProjectWorkspaceCreationRepository(
          id: "/tmp/source/shared",
          name: "Shared",
          rootURL: URL(fileURLWithPath: "/tmp/source/shared")
        )
        repository.role = " library "
        return repository
      }()
    ]
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
                .existing(renamedApp),
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

  @Test func submitInCreateModeCarriesDescriptionLinksAndRole() async {
    var repository = ProjectWorkspaceCreationRepository(
      id: "/tmp/repo-a",
      name: "Repo A",
      rootURL: URL(fileURLWithPath: "/tmp/repo-a")
    )
    repository.role = "app"
    var state = WorkspaceEditorFeature.State(
      repositories: [repository],
      title: "Solo",
      rootPath: "/tmp/solo-workspace"
    )
    state.description = "Just one"
    state.taskLinks = [WorkspaceTaskLinkDraft(id: "a", value: "PROWL-1")]
    let store = TestStore(initialState: state) {
      WorkspaceEditorFeature()
    }

    await store.send(.submitButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          .create(
            ProjectWorkspaceCreationDraft(
              title: "Solo",
              description: "Just one",
              taskLinks: ["PROWL-1"],
              rootURL: URL(filePath: "/tmp/solo-workspace", directoryHint: .isDirectory),
              repositories: [
                ProjectWorkspaceRepositoryPlan(
                  id: "/tmp/repo-a",
                  name: "Repo A",
                  role: "app",
                  path: nil,
                  sourceKind: .existingPath,
                  sourceLocation: "/tmp/repo-a",
                  checkout: .link
                )
              ]
            )
          )
        )
      )
    )
  }

  @Test func submitValidatesAddedRowsBeforeBuildingUpdate() async {
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
      $0.validationTarget = .repository("remote", .baseRef)
      $0.validationRequestID = 1
    }
  }
}
