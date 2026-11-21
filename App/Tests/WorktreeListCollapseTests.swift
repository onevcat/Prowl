import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Observation
import Sharing
import Testing

@testable import Prowl

@MainActor
@Suite(.serialized)
struct WorktreeListCollapseTests {
  // MARK: - Collapsed list

  @Test func shortListShowsEveryRowWithNoFooter() {
    let fixture = makeFixture(names: ["a", "b", "c"])
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.visibleRows(isShowingAll: false).map(\.id) == fixture.ids(["main", "a", "b", "c"]))
    #expect(sections.footer(isShowingAll: false) == nil)
    #expect(sections.footer(isShowingAll: true) == nil)
  }

  @Test func collapsedListShowsTheFirstFourRowsAndCountsTheRest() {
    let fixture = makeFixture(names: ["a", "b", "c", "d", "e", "f"])
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    expectNoDifference(
      sections.visibleRows(isShowingAll: false).map(\.id),
      fixture.ids(["main", "a", "b", "c"])
    )
    #expect(sections.footer(isShowingAll: false) == .showMore(count: 3))
  }

  @Test func rowWithATabStaysVisibleInItsPlace() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e", "f"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["e"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    expectNoDifference(
      sections.visibleRows(isShowingAll: false).map(\.id),
      fixture.ids(["main", "a", "b", "c", "e"])
    )
    #expect(sections.footer(isShowingAll: false) == .showMore(count: 2))
  }

  @Test func tabInTheFirstRowsDoesNotShowAnotherRow() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["a"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    expectNoDifference(
      sections.visibleRows(isShowingAll: false).map(\.id),
      fixture.ids(["main", "a", "b", "c"])
    )
  }

  @Test func pinnedRowsTakeTheFirstPlaces() {
    var fixture = makeFixture(names: ["p1", "a", "b", "c", "d"])
    fixture.state.pinnedWorktreeIDs = fixture.ids(["p1"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["d"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    expectNoDifference(
      sections.visibleRows(isShowingAll: false).map(\.id),
      fixture.ids(["main", "p1", "a", "b", "d"])
    )
    #expect(sections.footer(isShowingAll: false) == .showMore(count: 1))
  }

  @Test func everyPinnedRowShowsPastTheFirstFour() {
    var fixture = makeFixture(names: ["p1", "p2", "p3", "p4", "a", "b"])
    fixture.state.pinnedWorktreeIDs = fixture.ids(["p1", "p2", "p3", "p4"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["b"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    expectNoDifference(
      sections.visibleRows(isShowingAll: false).map(\.id),
      fixture.ids(["main", "p1", "p2", "p3", "p4", "b"])
    )
    #expect(sections.footer(isShowingAll: false) == .showMore(count: 1))
  }

  @Test func selectedAndPendingRowsStayVisible() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.selection = .worktree(fixture.id("e"))
    fixture.state.pendingWorktrees = [
      PendingWorktree(
        id: "/tmp/repo/pending",
        repositoryID: fixture.repository.id,
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName, worktreeName: "pending")
      )
    ]
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    expectNoDifference(
      sections.visibleRows(isShowingAll: false).map(\.id),
      [fixture.id("main"), "/tmp/repo/pending"] + fixture.ids(["a", "b", "e"])
    )
  }

  @Test func sidebarMultiSelectionStaysVisible() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.sidebarSelectedWorktreeIDs = Set(fixture.ids(["d", "e"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.footer(isShowingAll: false) == nil)
    #expect(sections.visibleRows(isShowingAll: false).count == 6)
  }

  @Test func repositoryWithoutAMainWorktreeShowsItsFirstFourRows() {
    let repoRoot = "/tmp/bare"
    let worktrees = ["a", "b", "c", "d", "e"].map {
      makeWorktree(id: "\(repoRoot)/\($0)", name: $0, repoRoot: "\(repoRoot)/repo.git")
    }
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "bare",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.worktreeOrderByRepository[repository.id] = worktrees.map(\.id)
    let sections = state.worktreeRowSections(in: repository)

    #expect(sections.main == nil)
    #expect(sections.visibleRows(isShowingAll: false).map(\.name) == ["a", "b", "c", "d"])
    #expect(sections.footer(isShowingAll: false) == .showMore(count: 1))
  }

  @Test func viewSplitWithTheParentsSelectionMatchesTheStateSplit() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.selection = .worktree(fixture.id("d"))
    fixture.state.sidebarSelectedWorktreeIDs = Set(fixture.ids(["d", "e"]))
    let parentSelection = SidebarListView.selectedWorktreeIDs(in: fixture.state)
      .filter { fixture.repository.worktrees[id: $0] != nil }

    let stateSections = fixture.state.worktreeRowSections(in: fixture.repository)
    let viewSections = fixture.state.worktreeRowSections(in: fixture.repository, keepingVisible: parentSelection)

    #expect(viewSections == stateSections)
    #expect(viewSections.hideableIDs.isEmpty)
  }

  @Test func nothingIsHiddenWhileTheLaunchLayoutRestoreIsPending() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.isLaunchLayoutRestorePending = true
    #expect(fixture.state.worktreeRowSections(in: fixture.repository).hideableIDs.isEmpty)

    fixture.state.isLaunchLayoutRestorePending = false
    #expect(fixture.state.worktreeRowSections(in: fixture.repository).hideableIDs == Set(fixture.ids(["d", "e"])))
  }

  @Test func plainAndRemoteFoldersHaveNothingToHide() {
    var fixture = makeFixture(names: ["a"])
    let plain = RemoteRepositoryFixtures.plainFolder()
    let remoteGit = RemoteRepositoryFixtures.gitRepository()
    fixture.state.repositories.append(plain)
    fixture.state.repositories.append(remoteGit)

    for repository in [plain, remoteGit] {
      let sections = fixture.state.worktreeRowSections(in: repository)
      #expect(sections.hideableIDs.isEmpty)
      #expect(sections.footer(isShowingAll: false) == nil)
    }
  }

  @Test func paletteRowsListEveryWorktree() {
    let fixture = makeFixture(names: ["a", "b", "c", "d", "e"])

    #expect(fixture.state.orderedWorktreeRows().map(\.id) == fixture.ids(["main", "a", "b", "c", "d", "e"]))
  }

  // MARK: - Showing all

  @Test func showingAllListsEveryRowInStoredOrder() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e", "f"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["d"]))
    fixture.state.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    // A row with a tab keeps its place between rows without one.
    expectNoDifference(
      fixture.state.visibleWorktreeRows(in: fixture.repository).map(\.id),
      fixture.ids(["main", "a", "b", "c", "d", "e", "f"])
    )
    #expect(sections.footer(isShowingAll: true) == .showLess(isEnabled: true))
  }

  @Test func showLessIsDisabledWhenNoRowCanBeHidden() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["d", "e"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.footer(isShowingAll: true) == .showLess(isEnabled: false))
    #expect(sections.footer(isShowingAll: false) == nil)
  }

  @Test func toggleShowsAllAndCollapsesAgain() async {
    let fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }

    await store.send(.toggleShowAllWorktrees(fixture.repository.id)) {
      $0.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    }
    #expect(store.state.visibleWorktreeRows(in: fixture.repository).count == 6)

    await store.send(.toggleShowAllWorktrees(fixture.repository.id)) {
      $0.$showAllWorktreesRepositoryIDs.withLock { $0 = [] }
    }
    #expect(store.state.visibleWorktreeRows(in: fixture.repository).count == 4)
  }

  @Test func reloadPrunesTheStateOfRemovedRepositories() async {
    let fixture = makeFixture(names: ["a"])
    fixture.state.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id, "/tmp/gone"] }
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded([fixture.repository], failures: [], roots: [fixture.repository.location], animated: false)
    )

    #expect(store.state.showAllWorktreesRepositoryIDs == [fixture.repository.id])
  }

  @Test func failedLoadKeepsTheStateOfThatRepository() async {
    let fixture = makeFixture(names: ["a"])
    fixture.state.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id, "/tmp/gone"] }
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

    #expect(store.state.showAllWorktreesRepositoryIDs == [fixture.repository.id])
  }

  // MARK: - Tabs

  @Test func firstTabShowsAHiddenRowAndLastTabCloseHidesIt() async {
    let fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }

    await store.send(.markWorktreeOpened(fixture.id("e"))) {
      $0.openedWorktreeIDs = [fixture.id("e")]
    }
    #expect(store.state.visibleWorktreeRows(in: fixture.repository).map(\.id).last == fixture.id("e"))

    await store.send(.markWorktreeClosed(fixture.id("e"))) {
      $0.openedWorktreeIDs = []
    }
    #expect(!store.state.visibleWorktreeRows(in: fixture.repository).map(\.id).contains(fixture.id("e")))
  }

  @Test func reopeningAnOpenWorktreeNotifiesNoObserver() {
    var fixture = makeFixture(names: ["a", "b"])
    fixture.state.openedWorktreeIDs = [fixture.id("a")]
    let store = Store(initialState: fixture.state) {
      RepositoriesFeature()
    }

    let notifiedOnReopen = LockIsolated(false)
    withObservationTracking {
      _ = store.openedWorktreeIDs
    } onChange: {
      notifiedOnReopen.setValue(true)
    }
    store.send(.markWorktreeOpened(fixture.id("a")))
    #expect(!notifiedOnReopen.value)

    // Control: opening a worktree that had no tab notifies.
    let notifiedOnOpen = LockIsolated(false)
    withObservationTracking {
      _ = store.openedWorktreeIDs
    } onChange: {
      notifiedOnOpen.setValue(true)
    }
    store.send(.markWorktreeOpened(fixture.id("b")))
    #expect(notifiedOnOpen.value)
  }

  // MARK: - Navigation

  @Test func navigationSkipsHiddenRowsAndWalksAllWhenShowingAll() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    let repositoryIDs: Set<Repository.ID> = [fixture.repository.id]

    expectNoDifference(
      fixture.state.navigableWorktreeRows(includingRepositoryIDs: repositoryIDs).map(\.id),
      fixture.ids(["main", "a", "b", "c"])
    )
    fixture.state.selection = .worktree(fixture.id("c"))
    #expect(fixture.state.worktreeID(byOffset: 1) == fixture.id("main"))

    fixture.state.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    #expect(fixture.state.worktreeID(byOffset: 1) == fixture.id("d"))
  }

  @Test func walkingAListThatShowsAllKeepsRowOrderAsTabsOpen() async {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.openedWorktreeIDs = [fixture.id("main")]
    fixture.state.selection = .worktree(fixture.id("main"))
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    var visited: [Worktree.ID?] = []
    for _ in 0..<6 {
      await store.send(.selectNextWorktree)
      await store.skipReceivedActions()
      visited.append(store.state.selectedWorktreeID)
    }
    expectNoDifference(visited, fixture.ids(["a", "b", "c", "d", "e", "main"]))
  }

  @Test func collapsedRepositoryGroupHidesEveryRow() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    let groupID = UUID()
    fixture.state.sidebarLayout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupID, title: "Product", repositoryIDs: [fixture.repository.id]))
    ])
    fixture.state.selection = .worktree(fixture.id("main"))
    fixture.state.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id] }

    fixture.state.$collapsedGroupIDs.withLock { $0 = [] }
    #expect(fixture.state.worktreeID(byOffset: 4) == fixture.id("d"))

    fixture.state.$collapsedGroupIDs.withLock { $0 = [groupID.uuidString] }
    #expect(fixture.state.worktreeID(byOffset: 1) == nil)
  }

  // MARK: - Removing the selected worktree

  @Test func removingTheSelectedWorktreeSelectsTheNextVisibleRow() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e", "f"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["c", "f"]))
    fixture.state.selection = .worktree(fixture.id("c"))
    let worktree = fixture.repository.worktrees[id: fixture.id("c")]!

    // Rows on screen: main, a, b, c, f; d and e are hidden.
    #expect(nextWorktreeID(afterRemoving: worktree, in: fixture.repository, state: fixture.state) == fixture.id("f"))
  }

  @Test func removingTheLastVisibleRowSelectsTheRowBeforeIt() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.selection = .worktree(fixture.id("c"))
    let worktree = fixture.repository.worktrees[id: fixture.id("c")]!

    #expect(nextWorktreeID(afterRemoving: worktree, in: fixture.repository, state: fixture.state) == fixture.id("b"))
  }

  // MARK: - Drag

  @Test func moveInACollapsedListMapsToTheFullOrder() async {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["e"]))

    // Visible unpinned rows a, b, c, e; d is hidden. Drag e before c: (3) -> 2 maps to (4) -> 2.
    let move = fixture.state.fullUnpinnedOrderMove(in: fixture.repository, offsets: [3], destination: 2)
    #expect(move?.offsets == [4])
    #expect(move?.destination == 2)

    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    guard let move else { return }
    await store.send(
      .worktreeOrdering(.unpinnedWorktreesMoved(repositoryID: fixture.repository.id, move.offsets, move.destination))
    ) {
      $0.worktreeOrderByRepository[fixture.repository.id] = fixture.ids(["a", "b", "e", "c", "d"])
    }
  }

  @Test func moveToTheEndOfACollapsedListLandsAfterTheLastVisibleRow() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["c"]))

    // Visible unpinned rows a, b, c; drag a to the end: (0) -> 3 maps to (0) -> 3, before hidden d.
    let move = fixture.state.fullUnpinnedOrderMove(in: fixture.repository, offsets: [0], destination: 3)
    #expect(move?.offsets == [0])
    #expect(move?.destination == 3)
  }

  @Test func moveInAListThatShowsAllMapsToItself() {
    var fixture = makeFixture(names: ["a", "b", "c", "d", "e"])
    fixture.state.$showAllWorktreesRepositoryIDs.withLock { $0 = [fixture.repository.id] }

    let move = fixture.state.fullUnpinnedOrderMove(in: fixture.repository, offsets: [4], destination: 0)
    #expect(move?.offsets == [4])
    #expect(move?.destination == 0)
  }

  @Test func moveOutOfRangeIsRejected() {
    let fixture = makeFixture(names: ["a", "b", "c", "d", "e"])

    #expect(fixture.state.fullUnpinnedOrderMove(in: fixture.repository, offsets: [3], destination: 0) == nil)
  }

  // MARK: - Fixtures

  private struct Fixture {
    var state: RepositoriesFeature.State
    let repository: Repository

    func id(_ name: String) -> Worktree.ID {
      name == "main" ? "/tmp/repo" : "/tmp/repo/\(name)"
    }

    func ids(_ names: [String]) -> [Worktree.ID] {
      names.map(id)
    }
  }

  /// Main plus the named worktrees in that stored order, none pinned and none with a tab.
  private func makeFixture(names: [String]) -> Fixture {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let others = names.map { makeWorktree(id: "\(repoRoot)/\($0)", name: $0, repoRoot: repoRoot) }
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main] + others)
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.location]
    state.worktreeOrderByRepository[repository.id] = others.map(\.id)
    return Fixture(state: state, repository: repository)
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
