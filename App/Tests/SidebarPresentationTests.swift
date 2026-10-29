import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import Prowl

@MainActor
struct SidebarPresentationTests {
  @Test func expandedRepositoryIsOneOuterItemWithChildRows() {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [main, feature])
    let state = makeState(repositories: [repository])

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [repository.id])

    let repositoryItems = presentation.repositoryRowItems
    #expect(repositoryItems.count == 1)
    guard case .repository(let model) = repositoryItems.first else {
      Issue.record("Expected repository container")
      return
    }
    #expect(model.id == repository.id)
    #expect(model.isExpanded)
    #expect(model.worktreeSections.allRows.map(\.id) == [main.id, feature.id])
  }

  @Test func collapsedRepositoryKeepsContainerButHidesChildRows() {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [main, feature])
    let state = makeState(repositories: [repository])

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [])

    guard case .repository(let model) = presentation.repositoryRowItems.first else {
      Issue.record("Expected repository container")
      return
    }
    #expect(!model.isExpanded)
    #expect(model.worktreeSections.allRows.isEmpty)
  }

  @Test func failedRepositoriesParticipateInRootOrder() {
    let repoA = makeRepository(id: "/tmp/a", worktrees: [])
    var state = makeState(repositories: [repoA])
    state.repositoryRoots = [
      .local(URL(fileURLWithPath: "/tmp/missing")),
      repoA.location,
    ]
    state.sidebarLayout = SidebarLayout(repositoryIDs: ["/tmp/missing", repoA.id])
    state.loadFailuresByID["/tmp/missing"] = "missing"

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [repoA.id])

    #expect(presentation.topLevelKeys == ["/tmp/missing", repoA.id])
    guard case .failedRepository(let failed) = presentation.repositoryRowItems.first else {
      Issue.record("Expected failed repository first")
      return
    }
    #expect(failed.id == "/tmp/missing")
    #expect(failed.isReorderable)
  }

  @Test func plainFolderProducesContainerWithoutWorktreeChildren() {
    let repository = makeRepository(id: "/tmp/plain", kind: .plain, worktrees: [])
    let state = makeState(repositories: [repository])

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [repository.id])

    guard case .repository(let model) = presentation.repositoryRowItems.first else {
      Issue.record("Expected repository container")
      return
    }
    #expect(model.kind == .plain)
    #expect(model.worktreeSections.allRows.isEmpty)
  }

  @Test func worktreeSectionsPreservePinnedMainPendingAndUnpinnedRows() {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let pinned = makeWorktree(id: "/tmp/repo/pinned", name: "pinned", repoRoot: repoRoot)
    let unpinned = makeWorktree(id: "/tmp/repo/unpinned", name: "unpinned", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [main, pinned, unpinned])
    var state = makeState(repositories: [repository])
    state.pinnedWorktreeIDs = [pinned.id]
    state.pendingWorktrees = [
      PendingWorktree(
        id: "/tmp/repo/pending",
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName, worktreeName: "pending")
      )
    ]
    state.worktreeOrderByRepository[repository.id] = [unpinned.id]

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [repository.id])

    guard case .repository(let model) = presentation.repositoryRowItems.first else {
      Issue.record("Expected repository container")
      return
    }
    #expect(model.worktreeSections.main?.id == main.id)
    #expect(model.worktreeSections.pinned.map(\.id) == [pinned.id])
    #expect(model.worktreeSections.pending.map(\.id) == ["/tmp/repo/pending"])
    #expect(model.worktreeSections.unpinned.map(\.id) == [unpinned.id])
  }

  @Test func emptyOrderedRootsStillBuildsRepositoryPresentation() {
    let repoA = makeRepository(id: "/tmp/a", worktrees: [])
    let repoB = makeRepository(id: "/tmp/b", worktrees: [])
    var state = RepositoriesFeature.State()
    state.repositories = [repoA, repoB]

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [repoA.id, repoB.id])

    #expect(presentation.topLevelKeys == [repoA.id, repoB.id])
  }

  @Test func customOrderedRootsUseSamePresentationRules() {
    let repoA = makeRepository(id: "/tmp/a", worktrees: [])
    let repoB = makeRepository(id: "/tmp/b", worktrees: [])
    var state = makeState(repositories: [repoA, repoB])
    state.sidebarLayout = SidebarLayout(repositoryIDs: [repoB.id, repoA.id])

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [repoA.id, repoB.id])

    #expect(presentation.topLevelKeys == [repoB.id, repoA.id])
  }

  @Test(.dependencies) func groupIsOneTopLevelItemWithItsMemberRows() {
    let groupID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let repoA = makeRepository(id: "/tmp/a", worktrees: [])
    let repoB = makeRepository(id: "/tmp/b", worktrees: [])
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryRoots.append(.local(URL(fileURLWithPath: "/tmp/missing")))
    state.loadFailuresByID["/tmp/missing"] = "missing"
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupID, title: "G", repositoryIDs: [repoB.id, "/tmp/missing", "/tmp/gone"]))
    ])

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [])

    #expect(presentation.topLevelKeys == [SidebarLayoutItem.groupKey(groupID), repoA.id])
    guard case .group(let group) = presentation.repositoryRowItems.first else {
      Issue.record("Expected the group first")
      return
    }
    #expect(group.isExpanded)
    #expect(group.memberCount == 2)
    #expect(group.members.map(\.id) == [.repository(repoB.id), .failedRepository("/tmp/missing")])
  }

  @Test(.dependencies) func collapsedGroupHasNoMemberRows() {
    let groupID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let repoA = makeRepository(id: "/tmp/a", worktrees: [])
    var state = makeState(repositories: [repoA])
    state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupID, title: "G", repositoryIDs: [repoA.id]))
    ])
    state.$collapsedGroupIDs.withLock { $0 = [groupID.uuidString] }

    let presentation = state.sidebarPresentation(expandedRepositoryIDs: [repoA.id])

    guard case .group(let group) = presentation.repositoryRowItems.first else {
      Issue.record("Expected the group")
      return
    }
    #expect(!group.isExpanded)
    #expect(group.memberCount == 1)
    #expect(group.members.isEmpty)
  }

  @Test func worktreeDropDestinationsMapToExistingOrderingActions() {
    let pinned = SidebarWorktreeDropTarget(
      repositoryID: "/tmp/repo",
      section: .pinned,
      source: IndexSet(integer: 1),
      destination: 0
    )
    let unpinned = SidebarWorktreeDropTarget(
      repositoryID: "/tmp/repo",
      section: .unpinned,
      source: IndexSet(integer: 0),
      destination: 2
    )

    #expect(
      pinned.action
        == RepositoriesFeature.WorktreeOrderingAction.pinnedWorktreesMoved(
          repositoryID: "/tmp/repo",
          IndexSet(integer: 1),
          0
        )
    )
    #expect(
      unpinned.action
        == RepositoriesFeature.WorktreeOrderingAction.unpinnedWorktreesMoved(
          repositoryID: "/tmp/repo",
          IndexSet(integer: 0),
          2
        )
    )
  }

  private func makeWorktree(id: String, name: String, repoRoot: String) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(
    id: String,
    kind: Repository.Kind = .git,
    worktrees: [Worktree]
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

extension SidebarPresentation {
  fileprivate var repositoryRowItems: [SidebarItem] {
    items.filter { $0.topLevelKey != nil }
  }
}
