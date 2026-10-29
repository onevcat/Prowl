import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import Prowl

@MainActor
struct RepositoriesFeatureSidebarGroupsTests {
  private let firstUUID = UUID(0)
  private let existingGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

  // MARK: - Group edits

  @Test(.dependencies) func newGroupPromptCreatesAGroupAtTheRepositoryPlace() async {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    let saved = LockIsolated<SidebarLayout?>(nil)
    let store = TestStore(initialState: makeState(repositories: [repoA, repoB])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.repositoryPersistence.saveSidebarLayout = { saved.setValue($0) }
    }

    await store.send(.sidebarGroups(.newGroupRequested(containing: repoB.id))) {
      $0.groupTitlePrompt = GroupTitlePrompt(target: .newGroup(containing: repoB.id), currentTitle: "")
    }
    await store.send(.sidebarGroups(.titlePromptSubmitted("  Product A  "))) {
      $0.groupTitlePrompt = nil
      $0.sidebarLayout = SidebarLayout(items: [
        .repository(repoA.id),
        .group(RepositoryGroup(id: self.firstUUID, title: "Product A", repositoryIDs: [repoB.id])),
      ])
    }
    await store.finish()
    #expect(saved.value == store.state.sidebarLayout)
  }

  @Test(.dependencies) func aBlankTitleCreatesNoGroup() async {
    let repoA = makeRepository(id: "/tmp/a")
    var state = makeState(repositories: [repoA])
    state.groupTitlePrompt = GroupTitlePrompt(target: .newGroup(containing: repoA.id), currentTitle: "")
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.sidebarGroups(.titlePromptSubmitted("   ")))
    await store.send(.sidebarGroups(.titlePromptCanceled)) {
      $0.groupTitlePrompt = nil
    }
  }

  @Test(.dependencies) func renamePromptRenamesTheGroup() async {
    let repoA = makeRepository(id: "/tmp/a")
    var state = makeState(repositories: [repoA])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "Old", repositoryIDs: [repoA.id]))
    ])
    let saved = LockIsolated<SidebarLayout?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveSidebarLayout = { saved.setValue($0) }
    }

    await store.send(.sidebarGroups(.renameGroupRequested(existingGroupID))) {
      $0.groupTitlePrompt = GroupTitlePrompt(target: .rename(self.existingGroupID), currentTitle: "Old")
    }
    await store.send(.sidebarGroups(.titlePromptSubmitted("New"))) {
      $0.groupTitlePrompt = nil
      $0.sidebarLayout = SidebarLayout(items: [
        .group(RepositoryGroup(id: self.existingGroupID, title: "New", repositoryIDs: [repoA.id]))
      ])
    }
    await store.finish()
    #expect(saved.value?.group(id: existingGroupID)?.title == "New")
  }

  @Test(.dependencies) func moveAndRemoveFromGroupMaterializeTheShownOrder() async {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    let repoC = makeRepository(id: "/tmp/c")
    var state = makeState(repositories: [repoA, repoB, repoC])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoB.id]))
    ])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.sidebarGroups(.moveRepositoryToGroup(repoC.id, existingGroupID))) {
      $0.sidebarLayout = SidebarLayout(items: [
        .group(RepositoryGroup(id: self.existingGroupID, title: "G", repositoryIDs: [repoB.id, repoC.id])),
        .repository(repoA.id),
      ])
    }
    await store.send(.sidebarGroups(.removeRepositoryFromGroup(repoB.id))) {
      $0.sidebarLayout = SidebarLayout(items: [
        .group(RepositoryGroup(id: self.existingGroupID, title: "G", repositoryIDs: [repoC.id])),
        .repository(repoB.id),
        .repository(repoA.id),
      ])
    }
  }

  @Test(.dependencies) func ungroupKeepsMembersAndForgetsTheCollapseState() async {
    let repoA = makeRepository(id: "/tmp/a")
    var state = makeState(repositories: [repoA])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id]))
    ])
    state.$collapsedGroupIDs.withLock { $0 = [existingGroupID.uuidString] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.sidebarGroups(.ungroup(existingGroupID))) {
      $0.sidebarLayout = SidebarLayout(repositoryIDs: [repoA.id])
      $0.$collapsedGroupIDs.withLock { $0 = [] }
    }
  }

  @Test(.dependencies) func setGroupColorUpdatesTheGroup() async {
    let repoA = makeRepository(id: "/tmp/a")
    var state = makeState(repositories: [repoA])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id]))
    ])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.sidebarGroups(.setGroupColor(existingGroupID, .mint))) {
      $0.sidebarLayout = SidebarLayout(items: [
        .group(RepositoryGroup(id: self.existingGroupID, title: "G", color: .mint, repositoryIDs: [repoA.id]))
      ])
    }
  }

  @Test(.dependencies) func sidebarItemMovedMovesARepositoryIntoAGroup() async {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    let repoC = makeRepository(id: "/tmp/c")
    var state = makeState(repositories: [repoA, repoB, repoC])
    state.sidebarLayout = SidebarLayout(items: [
      .repository(repoA.id),
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoB.id])),
      .repository(repoC.id),
    ])
    let saved = LockIsolated<SidebarLayout?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveSidebarLayout = { saved.setValue($0) }
    }

    await store.send(
      .worktreeOrdering(.sidebarItemMoved(.repository(repoC.id), .group(existingGroupID, before: repoB.id)))
    ) {
      $0.sidebarLayout = SidebarLayout(items: [
        .repository(repoA.id),
        .group(RepositoryGroup(id: self.existingGroupID, title: "G", repositoryIDs: [repoC.id, repoB.id])),
      ])
    }
    await store.finish()
    #expect(saved.value == store.state.sidebarLayout)
  }

  @Test(.dependencies) func sidebarItemMovedMovesAWholeGroupAndKeepsItsCollapse() async {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    var state = makeState(repositories: [repoA, repoB])
    state.sidebarLayout = SidebarLayout(items: [
      .repository(repoA.id),
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoB.id])),
    ])
    state.$collapsedGroupIDs.withLock { $0 = [existingGroupID.uuidString] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeOrdering(.sidebarItemMoved(.group(existingGroupID), .topLevel(before: repoA.id)))) {
      $0.sidebarLayout = SidebarLayout(items: [
        .group(RepositoryGroup(id: self.existingGroupID, title: "G", repositoryIDs: [repoB.id])),
        .repository(repoA.id),
      ])
    }
    #expect(store.state.collapsedGroupIDs == [existingGroupID.uuidString])
  }

  @Test(.dependencies) func sidebarItemMovedPlacesARootThatTheStoredLayoutLacks() async {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    var state = makeState(repositories: [repoA, repoB])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id]))
    ])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeOrdering(.sidebarItemMoved(.repository(repoB.id), .group(existingGroupID, before: nil)))
    ) {
      $0.sidebarLayout = SidebarLayout(items: [
        .group(RepositoryGroup(id: self.existingGroupID, title: "G", repositoryIDs: [repoA.id, repoB.id]))
      ])
    }
  }

  @Test(.dependencies) func aNoOpDropSavesNothing() async {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    var state = makeState(repositories: [repoA, repoB])
    state.sidebarLayout = SidebarLayout(repositoryIDs: [repoA.id, repoB.id])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveSidebarLayout = { _ in Issue.record("A no-op drop must not save") }
    }

    await store.send(.worktreeOrdering(.sidebarItemMoved(.repository(repoA.id), .topLevel(before: repoB.id))))
    await store.send(.worktreeOrdering(.sidebarItemMoved(.group(existingGroupID), .topLevel(before: nil))))
  }

  @Test(.dependencies) func aNoOpDropSavesNothingWhenTheStoredLayoutLacksARoot() async {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    var state = makeState(repositories: [repoA, repoB])
    state.sidebarLayout = SidebarLayout(repositoryIDs: [repoA.id])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveSidebarLayout = { _ in Issue.record("A no-op drop must not save") }
    }

    await store.send(.worktreeOrdering(.sidebarItemMoved(.repository(repoB.id), .topLevel(before: nil))))
  }

  // MARK: - Order and visibility

  @Test func orderedRepositoryIDsFlattenGroupsAndAppendUnknownRoots() {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    let repoC = makeRepository(id: "/tmp/c")
    var state = makeState(repositories: [repoA, repoB, repoC])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoC.id, repoA.id]))
    ])

    #expect(state.orderedRepositoryIDs() == [repoC.id, repoA.id, repoB.id])
  }

  @Test(.dependencies) func aCollapsedGroupHidesItsWorktreesFromNavigation() {
    let mainA = makeWorktree(id: "/tmp/a", repoRoot: "/tmp/a")
    let mainB = makeWorktree(id: "/tmp/b", repoRoot: "/tmp/b")
    let repoA = makeRepository(id: "/tmp/a", worktrees: [mainA])
    let repoB = makeRepository(id: "/tmp/b", worktrees: [mainB])
    var state = makeState(repositories: [repoA, repoB])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id])),
      .repository(repoB.id),
    ])
    state.$collapsedRepositoryIDs.withLock { $0 = [] }
    state.$collapsedGroupIDs.withLock { $0 = [existingGroupID.uuidString] }

    #expect(state.expandedRepositoryIDs == [repoA.id, repoB.id])
    #expect(state.visibleExpandedRepositoryIDs == [repoB.id])
    #expect(state.worktreeID(byOffset: 1) == mainB.id)
  }

  @Test(.dependencies) func selectionLeavesACollapsedGroupShut() async {
    let worktree = makeWorktree(id: "/tmp/a", repoRoot: "/tmp/a")
    let repoA = makeRepository(id: "/tmp/a", worktrees: [worktree])
    var state = makeState(repositories: [repoA])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id]))
    ])
    state.$collapsedGroupIDs.withLock { $0 = [existingGroupID.uuidString] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.selectWorktree(worktree.id))
    #expect(store.state.collapsedGroupIDs == [existingGroupID.uuidString])
  }

  @Test(.dependencies) func revealOpensTheGroupOfTheSelectedWorktree() async {
    let worktree = makeWorktree(id: "/tmp/a/wt", repoRoot: "/tmp/a")
    let repoA = makeRepository(id: "/tmp/a", worktrees: [worktree])
    var state = makeState(repositories: [repoA])
    state.selection = .worktree(worktree.id)
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id]))
    ])
    state.$collapsedRepositoryIDs.withLock { $0 = [repoA.id] }
    state.$collapsedGroupIDs.withLock { $0 = [existingGroupID.uuidString] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar) {
      $0.$collapsedRepositoryIDs.withLock { $0 = [] }
      $0.$collapsedGroupIDs.withLock { $0 = [] }
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = PendingSidebarReveal(id: 1, target: .worktree(worktree.id))
    }
  }

  @Test(.dependencies) func revealOpensTheGroupOfASelectedPlainFolder() async {
    let folder = makeRepository(id: "/tmp/folder", kind: .plain)
    var state = makeState(repositories: [folder])
    state.selection = .repository(folder.id)
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [folder.id]))
    ])
    state.$collapsedGroupIDs.withLock { $0 = [existingGroupID.uuidString] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar) {
      $0.$collapsedGroupIDs.withLock { $0 = [] }
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = PendingSidebarReveal(id: 1, target: .repository(folder.id))
    }
  }

  // MARK: - Pruning

  @Test func pruneRemovesGroupMembersButKeepsHiddenRemoteIDs() {
    let repoA = makeRepository(id: "/tmp/a")
    let hiddenRemote = RemoteRepositoryFixtures.location("/home/dev/app").id
    var state = makeState(repositories: [repoA])
    state.sidebarLayout = SidebarLayout(items: [
      .group(
        RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id, "/tmp/gone", hiddenRemote]))
    ])

    let didPrune = pruneSidebarLayout(
      roots: state.repositoryRoots, state: &state, keeping: { RepositoryLocation.hasRemoteForm($0) })

    #expect(didPrune)
    #expect(
      state.sidebarLayout
        == SidebarLayout(items: [
          .group(RepositoryGroup(id: existingGroupID, title: "G", repositoryIDs: [repoA.id, hiddenRemote]))
        ]))
  }

  // MARK: - Helpers

  private func makeWorktree(id: String, repoRoot: String) -> Worktree {
    Worktree(
      id: id,
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(
    id: String,
    kind: Repository.Kind = .git,
    worktrees: [Worktree] = []
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      kind: kind,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.location)
    return state
  }
}
