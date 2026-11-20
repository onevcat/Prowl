import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import Prowl

@MainActor
@Suite(.serialized)
struct FoldInactiveWorktreesTests {
  // MARK: - Section split

  @Test func worktreesWithoutAnOpenTabFoldWithNoSettingInvolved() {
    let fixture = makeFixture()
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.main?.id == fixture.main.id)
    #expect(sections.unpinned.isEmpty)
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id])
  }

  @Test func foldsWorktreesWithoutAnOpenTab() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.bravo.id]
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.unpinned.map(\.id) == [fixture.bravo.id])
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.charlie.id])
    #expect(sections.main?.id == fixture.main.id)
  }

  @Test func mainPinnedPendingAndSelectedWorktreesNeverFold() {
    var fixture = makeFixture()
    fixture.state.pinnedWorktreeIDs = [fixture.alpha.id]
    fixture.state.selection = .worktree(fixture.bravo.id)
    fixture.state.pendingWorktrees = [
      PendingWorktree(
        id: "/tmp/repo/pending",
        repositoryID: fixture.repository.id,
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName, worktreeName: "pending")
      )
    ]
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.main?.id == fixture.main.id)
    #expect(sections.pinned.map(\.id) == [fixture.alpha.id])
    #expect(sections.pending.map(\.id) == ["/tmp/repo/pending"])
    #expect(sections.unpinned.map(\.id) == [fixture.bravo.id])
    #expect(sections.inactive.map(\.id) == [fixture.charlie.id])
  }

  @Test func sidebarMultiSelectionKeepsRowsOutOfTheInactiveGroup() {
    var fixture = makeFixture()
    fixture.state.sidebarSelectedWorktreeIDs = [fixture.alpha.id, fixture.charlie.id]
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.inactive.map(\.id) == [fixture.bravo.id])
  }

  @Test func inactiveRowsKeepTheStoredUnpinnedOrder() {
    var fixture = makeFixture()
    fixture.state.worktreeOrderByRepository[fixture.repository.id] = [
      fixture.charlie.id, fixture.alpha.id, fixture.bravo.id,
    ]
    fixture.state.openedWorktreeIDs = [fixture.alpha.id]
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.unpinned.map(\.id) == [fixture.alpha.id])
    #expect(sections.inactive.map(\.id) == [fixture.charlie.id, fixture.bravo.id])
  }

  // MARK: - Moving between groups

  @Test func firstTabMovesAWorktreeOutOfTheInactiveGroupAndLastTabCloseBack() async {
    let fixture = makeFixture()
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }

    #expect(store.state.worktreeRowSections(in: fixture.repository).inactive.count == 3)

    await store.send(.markWorktreeOpened(fixture.bravo.id)) {
      $0.openedWorktreeIDs = [fixture.bravo.id]
    }
    var sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.unpinned.map(\.id) == [fixture.bravo.id])
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.charlie.id])

    await store.send(.markWorktreeClosed(fixture.bravo.id)) {
      $0.openedWorktreeIDs = []
    }
    sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.unpinned.isEmpty)
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id])
  }

  // MARK: - Navigation

  @Test func navigationSkipsFoldedRowsAndIncludesExpandedOnes() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.bravo.id]
    let repositoryIDs: Set<Repository.ID> = [fixture.repository.id]

    expectNoDifference(
      fixture.state.navigableWorktreeRows(includingRepositoryIDs: repositoryIDs).map(\.id),
      [fixture.main.id, fixture.bravo.id]
    )

    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    expectNoDifference(
      fixture.state.navigableWorktreeRows(includingRepositoryIDs: repositoryIDs).map(\.id),
      [fixture.main.id, fixture.bravo.id, fixture.alpha.id, fixture.charlie.id]
    )
  }

  @Test func offsetNavigationSkipsFoldedRows() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.bravo.id]
    fixture.state.selection = .worktree(fixture.main.id)

    #expect(fixture.state.worktreeID(byOffset: 1) == fixture.bravo.id)
    #expect(fixture.state.worktreeID(byOffset: -1) == fixture.bravo.id)

    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    #expect(fixture.state.worktreeID(byOffset: -1) == fixture.charlie.id)
  }

  @Test func selectNextWorktreeLandsOnTheNextActiveRow() async {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.charlie.id]
    fixture.state.selection = .worktree(fixture.main.id)
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(fixture.charlie.id)
      $0.sidebarSelectedWorktreeIDs = [fixture.charlie.id]
      $0.worktreeHistoryBackStack = [fixture.main.id]
      $0.pendingTerminalFocusWorktreeIDs = [fixture.charlie.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  // MARK: - Walking an expanded group

  @Test func nextWalksAnExpandedGroupInRowOrder() async {
    let fixture = makeExpandedGroupFixture()
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    var visited: [Worktree.ID?] = []
    for _ in 0..<4 {
      await store.send(.selectNextWorktree)
      await store.skipReceivedActions()
      visited.append(store.state.selectedWorktreeID)
    }
    expectNoDifference(
      visited,
      [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id, fixture.main.id]
    )
  }

  @Test func previousWalksAnExpandedGroupInRowOrder() async {
    let fixture = makeExpandedGroupFixture()
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    var visited: [Worktree.ID?] = []
    for _ in 0..<4 {
      await store.send(.selectPreviousWorktree)
      await store.skipReceivedActions()
      visited.append(store.state.selectedWorktreeID)
    }
    expectNoDifference(
      visited,
      [fixture.charlie.id, fixture.bravo.id, fixture.alpha.id, fixture.main.id]
    )
  }

  @Test func nextThenPreviousRetracesAnExpandedGroup() async {
    let fixture = makeExpandedGroupFixture()
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    var visited: [Worktree.ID?] = []
    for action in [
      RepositoriesFeature.Action.selectNextWorktree, .selectNextWorktree, .selectPreviousWorktree,
      .selectPreviousWorktree,
    ] {
      await store.send(action)
      await store.skipReceivedActions()
      visited.append(store.state.selectedWorktreeID)
    }
    expectNoDifference(visited, [fixture.alpha.id, fixture.bravo.id, fixture.alpha.id, fixture.main.id])
  }

  @Test func rowsKeepTheirPositionWhileTheGroupIsWalkedAndLeaveWhenSelectionLeavesIt() async {
    var fixture = makeFixture()
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.openedWorktreeIDs = [fixture.main.id]
    fixture.state.selection = .worktree(fixture.main.id)
    fixture.state.sidebarSelectedWorktreeIDs = [fixture.main.id]
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off
    let repositoryIDs: Set<Repository.ID> = [fixture.repository.id]
    let order = [fixture.main.id, fixture.alpha.id, fixture.bravo.id, fixture.charlie.id]

    await store.send(.selectWorktree(fixture.bravo.id))
    await store.skipReceivedActions()
    expectNoDifference(store.state.navigableWorktreeRows(includingRepositoryIDs: repositoryIDs).map(\.id), order)
    #expect(store.state.worktreeRowSections(in: fixture.repository).inactive.map(\.id).contains(fixture.bravo.id))

    // Selecting a row outside the group lets the rows opened from it leave.
    await store.send(.selectWorktree(fixture.main.id))
    await store.skipReceivedActions()
    let sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.unpinned.map(\.id) == [fixture.bravo.id])
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.charlie.id])
  }

  @Test func selectingAPlainFolderReleasesTheRowsKeptInTheGroup() async {
    var fixture = makeExpandedGroupFixture()
    let folder = Repository(
      id: "/tmp/notes",
      rootURL: URL(fileURLWithPath: "/tmp/notes"),
      name: "notes",
      kind: .plain,
      worktrees: []
    )
    fixture.state.repositories.append(folder)
    fixture.state.repositoryRoots.append(folder.location)
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.selectWorktree(fixture.bravo.id))
    await store.skipReceivedActions()
    await store.send(.selectRepository(folder.id))
    await store.skipReceivedActions()

    let sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.unpinned.map(\.id) == [fixture.bravo.id])
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.charlie.id])
  }

  @Test func selectingCanvasReleasesTheRowsKeptInTheGroup() async {
    let fixture = makeExpandedGroupFixture()
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.selectWorktree(fixture.bravo.id))
    await store.skipReceivedActions()
    await store.send(.selectCanvas)
    await store.finish()

    let sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.unpinned.map(\.id) == [fixture.bravo.id])
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.charlie.id])
  }

  @Test func foldingTheGroupReleasesTheRowsKeptInIt() async {
    var fixture = makeFixture()
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.openedWorktreeIDs = [fixture.main.id]
    fixture.state.selection = .worktree(fixture.main.id)
    fixture.state.sidebarSelectedWorktreeIDs = [fixture.main.id]
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.selectWorktree(fixture.bravo.id))
    await store.skipReceivedActions()
    await store.send(.selectWorktree(fixture.charlie.id))
    await store.skipReceivedActions()
    await store.send(.toggleInactiveWorktreesExpanded(fixture.repository.id))

    let sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(Set(sections.unpinned.map(\.id)) == [fixture.bravo.id, fixture.charlie.id])
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id])
  }

  @Test func foldingComposesWithASidebarGroup() {
    var fixture = makeFixture()
    let groupID = UUID()
    fixture.state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupID, title: "Product", repositoryIDs: [fixture.repository.id]))
    ])
    fixture.state.openedWorktreeIDs = [fixture.main.id, fixture.bravo.id]
    fixture.state.selection = .worktree(fixture.main.id)
    fixture.state.$collapsedGroupIDs.withLock { $0 = [] }

    // In an open group, the repository folds as it does at the top level.
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.charlie.id])
    #expect(fixture.state.worktreeID(byOffset: 1) == fixture.bravo.id)
    #expect(fixture.state.worktreeID(byOffset: 2) == fixture.main.id)

    // A collapsed group hides every row of the repository, the Inactive group included.
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.$collapsedGroupIDs.withLock { $0 = [groupID.uuidString] }
    #expect(fixture.state.worktreeID(byOffset: 1) == nil)
  }

  @Test func paletteRowsStillListEveryWorktree() {
    var fixture = makeFixture()
    let allIDs = Set(fixture.state.orderedWorktreeRows().map(\.id))
    fixture.state.openedWorktreeIDs = [fixture.bravo.id]

    #expect(Set(fixture.state.orderedWorktreeRows().map(\.id)) == allIDs)
    #expect(allIDs.contains(fixture.alpha.id))
    #expect(fixture.state.worktreeRowSections(in: fixture.repository).allRows.count == allIDs.count)
  }

  @Test func collapsedRepositoryStaysOutOfNavigationWhateverTheInactiveState() {
    let fixture = makeFixture()
    fixture.state.$collapsedRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }

    #expect(fixture.state.worktreeID(byOffset: 1) == nil)
  }

  // MARK: - Fold state

  @Test func toggleExpandsAndFoldsTheInactiveGroup() async {
    let fixture = makeFixture()
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }

    await store.send(.toggleInactiveWorktreesExpanded(fixture.repository.id)) {
      $0.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    }
    #expect(store.state.isInactiveWorktreesExpanded(in: fixture.repository.id))

    await store.send(.toggleInactiveWorktreesExpanded(fixture.repository.id)) {
      $0.$expandedInactiveRepositoryIDs.withLock { $0 = [] }
    }
    #expect(!store.state.isInactiveWorktreesExpanded(in: fixture.repository.id))
  }

  @Test func reloadPrunesExpandedStateOfRemovedRepositories() async {
    let fixture = makeFixture()
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id, "/tmp/gone"] }
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [fixture.repository],
        failures: [],
        roots: [fixture.repository.location],
        animated: false
      )
    )

    #expect(store.state.expandedInactiveRepositoryIDs == [fixture.repository.id])
  }

  @Test func failedLoadKeepsExpandedStateOfThatRepository() async {
    let fixture = makeFixture()
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id, "/tmp/gone"] }
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: fixture.repository.id, message: "boom")],
        roots: [fixture.repository.location],
        animated: false
      )
    )

    #expect(store.state.expandedInactiveRepositoryIDs == [fixture.repository.id])
  }

  // MARK: - Drag

  @Test func moveInsideTheUnpinnedGroupMapsToTheFullOrder() async {
    var fixture = makeFixture()
    // Full order a, b, c; b is inactive, so the visible unpinned group is a, c.
    fixture.state.worktreeOrderByRepository[fixture.repository.id] = [
      fixture.alpha.id, fixture.bravo.id, fixture.charlie.id,
    ]
    fixture.state.openedWorktreeIDs = [fixture.alpha.id, fixture.charlie.id]

    // Drag c before a: group offsets (1) -> 0 map to full offsets (2) -> 0.
    let move = fixture.state.fullUnpinnedOrderMove(
      in: fixture.repository,
      section: .unpinned,
      offsets: IndexSet(integer: 1),
      destination: 0
    )
    #expect(move?.offsets == IndexSet(integer: 2))
    #expect(move?.destination == 0)

    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    guard let move else { return }
    await store.send(
      .worktreeOrdering(
        .unpinnedWorktreesMoved(repositoryID: fixture.repository.id, move.offsets, move.destination)
      )
    ) {
      $0.worktreeOrderByRepository[fixture.repository.id] = [fixture.charlie.id, fixture.alpha.id, fixture.bravo.id]
    }
  }

  @Test func moveToTheEndOfTheUnpinnedGroupLandsAfterItsLastRow() {
    var fixture = makeFixture()
    fixture.state.worktreeOrderByRepository[fixture.repository.id] = [
      fixture.alpha.id, fixture.bravo.id, fixture.charlie.id,
    ]
    fixture.state.openedWorktreeIDs = [fixture.alpha.id, fixture.charlie.id]

    // Drag a after c: group offsets (0) -> 2 map to full offsets (0) -> 3.
    let move = fixture.state.fullUnpinnedOrderMove(
      in: fixture.repository,
      section: .unpinned,
      offsets: IndexSet(integer: 0),
      destination: 2
    )
    #expect(move?.offsets == IndexSet(integer: 0))
    #expect(move?.destination == 3)
  }

  @Test func moveInsideTheInactiveGroupWritesOneStoredOrder() async {
    var fixture = makeFixture()
    fixture.state.worktreeOrderByRepository[fixture.repository.id] = [
      fixture.alpha.id, fixture.bravo.id, fixture.charlie.id,
    ]
    fixture.state.openedWorktreeIDs = [fixture.bravo.id]

    // Inactive group is a, c. Drag c before a.
    let move = fixture.state.fullUnpinnedOrderMove(
      in: fixture.repository,
      section: .inactive,
      offsets: IndexSet(integer: 1),
      destination: 0
    )
    #expect(move?.offsets == IndexSet(integer: 2))
    #expect(move?.destination == 0)

    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    guard let move else { return }
    await store.send(
      .worktreeOrdering(
        .unpinnedWorktreesMoved(repositoryID: fixture.repository.id, move.offsets, move.destination)
      )
    ) {
      $0.worktreeOrderByRepository[fixture.repository.id] = [fixture.charlie.id, fixture.alpha.id, fixture.bravo.id]
    }
  }

  @Test func moveWithoutFoldedRowsMapsToItself() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id]
    let move = fixture.state.fullUnpinnedOrderMove(
      in: fixture.repository,
      section: .unpinned,
      offsets: IndexSet(integer: 0),
      destination: 3
    )

    #expect(move?.offsets == IndexSet(integer: 0))
    #expect(move?.destination == 3)
  }

  @Test func moveOutsideTheGroupIsRejected() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id]

    #expect(
      fixture.state.fullUnpinnedOrderMove(
        in: fixture.repository,
        section: .inactive,
        offsets: IndexSet(integer: 0),
        destination: 0
      ) == nil
    )
  }

  // MARK: - Folders

  @Test func plainAndRemoteFoldersHaveNothingToFold() {
    var fixture = makeFixture()
    let plain = RemoteRepositoryFixtures.plainFolder()
    let remoteGit = RemoteRepositoryFixtures.gitRepository()
    fixture.state.repositories.append(plain)
    fixture.state.repositories.append(remoteGit)

    for repository in [plain, remoteGit] {
      let sections = fixture.state.worktreeRowSections(in: repository)
      #expect(sections.inactive.isEmpty)
      #expect(sections.unpinned.isEmpty)
    }
    #expect(fixture.state.worktreeRowSections(in: remoteGit).main?.id == remoteGit.worktrees.first?.id)
    #expect(fixture.state.worktreeRowSections(in: plain).main == nil)
  }

  @Test func foldersDoNotShiftTheNavigableRowsOfGitRepositories() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.bravo.id]
    let plain = RemoteRepositoryFixtures.plainFolder()
    let remoteGit = RemoteRepositoryFixtures.gitRepository()
    fixture.state.repositories.append(plain)
    fixture.state.repositories.append(remoteGit)
    fixture.state.repositoryRoots.append(contentsOf: [plain.location, remoteGit.location])
    let repositoryIDs = Set(fixture.state.repositories.map(\.id))

    let ids = fixture.state.navigableWorktreeRows(includingRepositoryIDs: repositoryIDs).map(\.id)

    #expect(ids.prefix(2) == [fixture.main.id, fixture.bravo.id])
    #expect(ids.count == 3)
    #expect(ids.last == remoteGit.worktrees.first?.id)
    #expect(!ids.contains(plain.id))
  }

  // MARK: - Fixtures

  private struct Fixture {
    var state: RepositoriesFeature.State
    let repository: Repository
    let main: Worktree
    let alpha: Worktree
    let bravo: Worktree
    let charlie: Worktree
  }

  private func makeFixture() -> Fixture {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let bravo = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let charlie = makeWorktree(id: "/tmp/repo/c", name: "c", repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, alpha, bravo, charlie])
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.location]
    return Fixture(state: state, repository: repository, main: main, alpha: alpha, bravo: bravo, charlie: charlie)
  }

  /// Main is open and selected; a, b, and c have no tab; the repository's
  /// Inactive group is expanded.
  private func makeExpandedGroupFixture() -> Fixture {
    var fixture = makeFixture()
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.openedWorktreeIDs = [fixture.main.id]
    fixture.state.selection = .worktree(fixture.main.id)
    fixture.state.sidebarSelectedWorktreeIDs = [fixture.main.id]
    return fixture
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
}
