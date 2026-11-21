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
struct FoldInactiveWorktreesTests {
  // MARK: - Section split

  @Test func everyUnpinnedWorktreeFoldsWhenNoneHasATab() {
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
    fixture.state.pinnedWorktreeIDs.append(fixture.alpha.id)
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
    #expect(sections.pinned.map(\.id) == [fixture.pinnedOne.id, fixture.pinnedTwo.id, fixture.alpha.id])
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

  @Test func viewSplitWithTheParentsSelectionMatchesTheStateSplit() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.alpha.id]
    fixture.state.selection = .worktree(fixture.bravo.id)
    fixture.state.sidebarSelectedWorktreeIDs = [fixture.bravo.id, fixture.charlie.id]
    // The rows view passes the selected worktrees `SidebarListView` resolved for its repository.
    let parentSelection = SidebarListView.selectedWorktreeIDs(in: fixture.state)
      .filter { fixture.repository.worktrees[id: $0] != nil }

    let stateSections = fixture.state.worktreeRowSections(in: fixture.repository)
    let viewSections = fixture.state.worktreeRowSections(
      in: fixture.repository,
      keepingUnfolded: parentSelection
    )

    #expect(viewSections == stateSections)
    #expect(viewSections.unpinned.map(\.id) == [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id])
    #expect(viewSections.inactive.isEmpty)
  }

  @Test func viewSplitFoldsWhatTheParentDidNotSelect() {
    var fixture = makeFixture()
    fixture.state.selection = .worktree(fixture.bravo.id)

    let sections = fixture.state.worktreeRowSections(in: fixture.repository, keepingUnfolded: [])

    #expect(sections.unpinned.isEmpty)
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id])
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

  // MARK: - Minimum visible rows

  @Test func repositoryWithFewWorktreesFoldsNothing() {
    let fixture = makeSmallFixture(names: ["a", "b"])
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.unpinned.map(\.id) == fixture.ids(["a", "b"]))
    #expect(sections.inactive.isEmpty)
  }

  @Test func inactiveRowsFillTheFloorInRowOrderAndTheRestFold() {
    let fixture = makeSmallFixture(names: ["a", "b", "c", "d"])
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.main?.id == fixture.main.id)
    #expect(sections.unpinned.map(\.id) == fixture.ids(["a", "b"]))
    #expect(sections.inactive.map(\.id) == fixture.ids(["c", "d"]))
  }

  @Test func activeRowsCountTowardTheFloor() {
    var fixture = makeSmallFixture(names: ["a", "b", "c", "d"])
    fixture.state.openedWorktreeIDs = Set(fixture.ids(["c"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.unpinned.map(\.id) == fixture.ids(["a", "c"]))
    #expect(sections.inactive.map(\.id) == fixture.ids(["b", "d"]))
  }

  @Test func pinnedAndPendingRowsCountTowardTheFloor() {
    var fixture = makeSmallFixture(names: ["a", "b", "c", "d"])
    fixture.state.pinnedWorktreeIDs = fixture.ids(["a"])
    fixture.state.pendingWorktrees = [
      PendingWorktree(
        id: "/tmp/small/pending",
        repositoryID: fixture.repository.id,
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName, worktreeName: "pending")
      )
    ]
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.unpinned.isEmpty)
    #expect(sections.inactive.map(\.id) == fixture.ids(["b", "c", "d"]))
  }

  @Test func rowsKeptInTheExpandedGroupDoNotFillTheFloor() {
    var fixture = makeSmallFixture(names: ["a", "b", "c", "d"])
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.retainedInactiveWorktreeIDs = Set(fixture.ids(["a"]))
    let sections = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(sections.unpinned.map(\.id) == fixture.ids(["b", "c"]))
    #expect(sections.inactive.map(\.id) == fixture.ids(["a", "d"]))
  }

  @Test func navigationWalksTheRowsThatFillTheFloor() {
    let fixture = makeSmallFixture(names: ["a", "b", "c", "d"])

    expectNoDifference(
      fixture.state.navigableWorktreeRows(includingRepositoryIDs: [fixture.repository.id]).map(\.id),
      [fixture.main.id] + fixture.ids(["a", "b"])
    )
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
      [fixture.main.id, fixture.pinnedOne.id, fixture.pinnedTwo.id, fixture.bravo.id]
    )

    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    expectNoDifference(
      fixture.state.navigableWorktreeRows(includingRepositoryIDs: repositoryIDs).map(\.id),
      [
        fixture.main.id, fixture.pinnedOne.id, fixture.pinnedTwo.id, fixture.bravo.id, fixture.alpha.id,
        fixture.charlie.id,
      ]
    )
  }

  @Test func offsetNavigationSkipsFoldedRows() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.bravo.id]
    fixture.state.selection = .worktree(fixture.bravo.id)

    #expect(fixture.state.worktreeID(byOffset: 1) == fixture.main.id)
    #expect(fixture.state.worktreeID(byOffset: -1) == fixture.pinnedTwo.id)

    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    #expect(fixture.state.worktreeID(byOffset: 1) == fixture.alpha.id)
  }

  @Test func selectNextWorktreeLandsOnTheNextActiveRow() async {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.pinnedTwo.id, fixture.charlie.id]
    fixture.state.selection = .worktree(fixture.pinnedTwo.id)
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(fixture.charlie.id)
      $0.sidebarSelectedWorktreeIDs = [fixture.charlie.id]
      $0.worktreeHistoryBackStack = [fixture.pinnedTwo.id]
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
    var fixture = makeExpandedGroupFixture()
    fixture.state.selection = .worktree(fixture.main.id)
    fixture.state.sidebarSelectedWorktreeIDs = [fixture.main.id]
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
      [fixture.charlie.id, fixture.bravo.id, fixture.alpha.id, fixture.pinnedTwo.id]
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
    expectNoDifference(visited, [fixture.alpha.id, fixture.bravo.id, fixture.alpha.id, fixture.pinnedTwo.id])
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
    let order = [
      fixture.main.id, fixture.pinnedOne.id, fixture.pinnedTwo.id, fixture.alpha.id, fixture.bravo.id,
      fixture.charlie.id,
    ]

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
    fixture.state.selection = .worktree(fixture.pinnedTwo.id)
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

    #expect(ids.prefix(4) == [fixture.main.id, fixture.pinnedOne.id, fixture.pinnedTwo.id, fixture.bravo.id])
    #expect(ids.count == 5)
    #expect(ids.last == remoteGit.worktrees.first?.id)
    #expect(!ids.contains(plain.id))
  }

  // MARK: - Removing the selected worktree

  @Test func removingTheSelectedWorktreeSelectsTheNextVisibleRowPastAFoldedGroup() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.main.id, fixture.alpha.id, fixture.charlie.id]
    fixture.state.selection = .worktree(fixture.alpha.id)

    // Stored order a, b, c; b is folded, so the row after a on screen is c.
    let next = nextWorktreeID(afterRemoving: fixture.alpha, in: fixture.repository, state: fixture.state)

    #expect(next == fixture.charlie.id)
  }

  @Test func removingTheLastVisibleRowSelectsTheVisibleRowBeforeIt() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.main.id, fixture.alpha.id, fixture.charlie.id]
    fixture.state.selection = .worktree(fixture.charlie.id)

    let next = nextWorktreeID(afterRemoving: fixture.charlie, in: fixture.repository, state: fixture.state)

    #expect(next == fixture.alpha.id)
  }

  @Test func removingTheSelectedWorktreeWalksAnExpandedGroupInRowOrder() {
    var fixture = makeFixture()
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.openedWorktreeIDs = [fixture.main.id, fixture.alpha.id, fixture.charlie.id]
    fixture.state.selection = .worktree(fixture.charlie.id)

    // Rows on screen: main, a, c, then the expanded group with b.
    let next = nextWorktreeID(afterRemoving: fixture.charlie, in: fixture.repository, state: fixture.state)

    #expect(next == fixture.bravo.id)
  }

  // MARK: - Observation

  @Test func reopeningAnOpenWorktreeNotifiesNoObserver() {
    var fixture = makeFixture()
    fixture.state.openedWorktreeIDs = [fixture.alpha.id]
    let store = Store(initialState: fixture.state) {
      RepositoriesFeature()
    }

    let notifiedOnReopen = LockIsolated(false)
    withObservationTracking {
      _ = store.openedWorktreeIDs
    } onChange: {
      notifiedOnReopen.setValue(true)
    }
    store.send(.markWorktreeOpened(fixture.alpha.id))
    #expect(!notifiedOnReopen.value)

    // Control: opening a worktree that had no tab notifies.
    let notifiedOnOpen = LockIsolated(false)
    withObservationTracking {
      _ = store.openedWorktreeIDs
    } onChange: {
      notifiedOnOpen.setValue(true)
    }
    store.send(.markWorktreeOpened(fixture.bravo.id))
    #expect(notifiedOnOpen.value)
  }

  // MARK: - Launch

  @Test func nothingFoldsWhileTheLaunchLayoutRestoreIsPending() {
    var fixture = makeFixture()
    fixture.state.isLaunchLayoutRestorePending = true
    let pending = fixture.state.worktreeRowSections(in: fixture.repository)

    #expect(pending.inactive.isEmpty)
    #expect(pending.unpinned.map(\.id) == [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id])

    fixture.state.isLaunchLayoutRestorePending = false
    #expect(fixture.state.worktreeRowSections(in: fixture.repository).unpinned.isEmpty)
  }

  // MARK: - Multi-selection and kept rows

  @Test func commandClickInAnExpandedGroupKeepsTheRowInTheGroup() async {
    let fixture = makeExpandedGroupFixture()
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.setSidebarSelectedWorktreeIDs([fixture.main.id, fixture.bravo.id]))
    var sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id])
    #expect(sections.unpinned.isEmpty)

    // A plain click outside the group releases the row.
    await store.send(.selectWorktree(fixture.main.id))
    await store.skipReceivedActions()
    #expect(store.state.retainedInactiveWorktreeIDs.isEmpty)
    sections = store.state.worktreeRowSections(in: fixture.repository)
    #expect(sections.inactive.map(\.id) == [fixture.alpha.id, fixture.bravo.id, fixture.charlie.id])
  }

  @Test func selectingInAnotherRepositorysGroupReleasesTheRowsKeptInTheFirst() async {
    var fixture = makeExpandedGroupFixture()
    let otherRoot = "/tmp/other"
    let otherMain = makeWorktree(id: otherRoot, name: "main", repoRoot: otherRoot)
    // Main, a, and b fill the floor, so c folds.
    let otherWorktrees = ["a", "b", "c"].map {
      makeWorktree(id: "/tmp/other/\($0)", name: $0, repoRoot: otherRoot)
    }
    let otherCharlie = otherWorktrees[2]
    let other = Repository(
      id: otherRoot,
      rootURL: URL(fileURLWithPath: otherRoot),
      name: "other",
      worktrees: IdentifiedArray(uniqueElements: [otherMain] + otherWorktrees)
    )
    fixture.state.repositories.append(other)
    fixture.state.repositoryRoots.append(other.location)
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id, other.id] }
    let store = TestStore(initialState: fixture.state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.selectWorktree(fixture.alpha.id))
    await store.skipReceivedActions()
    #expect(store.state.retainedInactiveWorktreeIDs == [fixture.alpha.id])

    await store.send(.selectWorktree(otherCharlie.id))
    await store.skipReceivedActions()
    #expect(store.state.retainedInactiveWorktreeIDs == [otherCharlie.id])
    // a has a tab now, so it leaves the first repository's group.
    #expect(store.state.worktreeRowSections(in: fixture.repository).unpinned.map(\.id) == [fixture.alpha.id])
  }

  // MARK: - Fixtures

  private struct Fixture {
    var state: RepositoriesFeature.State
    let repository: Repository
    let main: Worktree
    let pinnedOne: Worktree
    let pinnedTwo: Worktree
    let alpha: Worktree
    let bravo: Worktree
    let charlie: Worktree
  }

  /// Main and two pinned worktrees fill `minimumVisibleWorktreeRows`, so a, b, and c
  /// fold exactly when they are inactive.
  private func makeFixture() -> Fixture {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let pinnedOne = makeWorktree(id: "/tmp/repo/p1", name: "p1", repoRoot: repoRoot)
    let pinnedTwo = makeWorktree(id: "/tmp/repo/p2", name: "p2", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let bravo = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let charlie = makeWorktree(id: "/tmp/repo/c", name: "c", repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, pinnedOne, pinnedTwo, alpha, bravo, charlie])
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.location]
    state.pinnedWorktreeIDs = [pinnedOne.id, pinnedTwo.id]
    return Fixture(
      state: state,
      repository: repository,
      main: main,
      pinnedOne: pinnedOne,
      pinnedTwo: pinnedTwo,
      alpha: alpha,
      bravo: bravo,
      charlie: charlie
    )
  }

  /// The last pinned worktree is open and selected; a, b, and c have no tab; the
  /// repository's Inactive group is expanded.
  private func makeExpandedGroupFixture() -> Fixture {
    var fixture = makeFixture()
    fixture.state.$expandedInactiveRepositoryIDs.withLock { $0 = [fixture.repository.id] }
    fixture.state.openedWorktreeIDs = [fixture.main.id, fixture.pinnedTwo.id]
    fixture.state.selection = .worktree(fixture.pinnedTwo.id)
    fixture.state.sidebarSelectedWorktreeIDs = [fixture.pinnedTwo.id]
    return fixture
  }

  private struct SmallFixture {
    var state: RepositoriesFeature.State
    let repository: Repository
    let main: Worktree

    func ids(_ names: [String]) -> [Worktree.ID] {
      names.map { "/tmp/small/\($0)" }
    }
  }

  /// Main plus the named worktrees, none pinned and none with a tab.
  private func makeSmallFixture(names: [String]) -> SmallFixture {
    let repoRoot = "/tmp/small"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let others = names.map { makeWorktree(id: "\(repoRoot)/\($0)", name: $0, repoRoot: repoRoot) }
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "small",
      worktrees: IdentifiedArray(uniqueElements: [main] + others)
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.location]
    state.worktreeOrderByRepository[repository.id] = others.map(\.id)
    return SmallFixture(state: state, repository: repository, main: main)
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
