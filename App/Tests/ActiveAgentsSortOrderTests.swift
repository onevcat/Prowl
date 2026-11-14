import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import Prowl

@MainActor
struct ActiveAgentsSortOrderTests {
  // MARK: - Sections

  @Test func startTimeKeepsTheDetectionOrderInOneSection() {
    let entries = makeEntries([.idle, .blocked, .working])

    #expect(
      sections(entries, .startTime) == [
        ActiveAgentSection(kind: .all, entryIDs: [agentID(0), agentID(1), agentID(2)])
      ])
  }

  @Test func statusPutsBlockedFirstAndKeepsTheStartOrderInsideAStatus() {
    let entries = makeEntries([.idle, .working, .done, .blocked, .working, .blocked])

    #expect(
      sections(entries, .status) == [
        ActiveAgentSection(
          kind: .all,
          entryIDs: [agentID(3), agentID(5), agentID(1), agentID(4), agentID(2), agentID(0)]
        )
      ])
  }

  @Test func projectGroupsInSidebarOrderWithOtherLast() {
    let entries = makeEntries([.idle, .idle, .idle, .idle, .idle])
    let projectIDs: [ActiveAgentEntry.ID: Repository.ID] = [
      agentID(0): "/b", agentID(1): "/a", agentID(3): "/b", agentID(4): "/unlisted",
    ]

    let result = ActiveAgentsOrdering.sections(
      entries: entries,
      sortOrder: .project,
      projectIDs: projectIDs,
      projectOrder: ["/a", "/empty", "/b"]
    )

    #expect(
      result == [
        ActiveAgentSection(kind: .project("/a"), entryIDs: [agentID(1)]),
        ActiveAgentSection(kind: .project("/b"), entryIDs: [agentID(0), agentID(3)]),
        ActiveAgentSection(kind: .project("/unlisted"), entryIDs: [agentID(4)]),
        ActiveAgentSection(kind: .other, entryIDs: [agentID(2)]),
      ])
  }

  @Test func noEntriesMakeNoSections() {
    #expect(sections([], .startTime).isEmpty)
    #expect(sections([], .project).isEmpty)
  }

  @Test func orderedEntriesFlattenTheSections() {
    var state = ActiveAgentsFeature.State()
    state.entries = makeEntries([.idle, .blocked])
    #expect(state.orderedEntries.map(\.id) == [agentID(0), agentID(1)])

    state.sortOrder = .status
    #expect(state.orderedEntries.map(\.id) == [agentID(1), agentID(0)])
  }

  // MARK: - Navigation

  @Test func nextAgentFollowsTheStatusOrder() async {
    var state = ActiveAgentsFeature.State()
    state.entries = makeEntries([.idle, .blocked, .working])
    state.sortOrder = .status
    state.focusedSurfaceID = agentID(1)
    let store = TestStore(initialState: state) {
      ActiveAgentsFeature()
    }

    await store.send(.selectNextEntry) {
      $0.focusedSurfaceID = agentID(2)
    }
    await store.receive(.entryTapped(agentID(2)))
  }

  @Test func islandDigitsFollowTheProjectOrder() async {
    var state = ActiveAgentsFeature.State()
    state.entries = makeEntries([.idle, .idle])
    state.sortOrder = .project
    state.projectIDsByEntryID = [agentID(0): "/b", agentID(1): "/a"]
    state.projectOrder = ["/a", "/b"]
    state.isIslandRosterExpanded = true
    let store = TestStore(initialState: state) {
      ActiveAgentsFeature()
    }

    await store.send(.islandActivateVisibleEntry(0))
    await store.receive(.island(.entryTapped(agentID(1)))) {
      $0.isIslandRosterExpanded = false
      $0.islandNavigation = .init()
    }
    await store.receive(.entryTapped(agentID(1))) {
      $0.focusedSurfaceID = agentID(1)
    }
  }

  // MARK: - Project resolution in RepositoriesFeature

  @Test func projectOfAnAgentFollowsItsRowRepository() {
    let folderA = makePlainRepository("/tmp/prowl-sort-a")
    let folderB = makePlainRepository("/tmp/prowl-sort-b")
    let entries: IdentifiedArrayOf<ActiveAgentEntry> = [
      // No working directory: the tab's owning folder.
      makeEntry(agentID(0), worktreeID: folderB.id),
      // A working directory outside every repository: no project, even though the tab is
      // owned by a known folder.
      makeEntry(agentID(1), worktreeID: folderA.id, workingDirectory: URL(filePath: "/nowhere/else")),
    ]

    let projectIDs = RepositoriesFeature.State.activeAgentProjectIDs(
      entries: entries,
      repositories: [folderA, folderB]
    )

    #expect(projectIDs == [agentID(0): folderB.id])
  }

  @Test func refreshFillsTheProjectOrderOnlyInProjectMode() {
    let folderA = makePlainRepository("/tmp/prowl-sort-a")
    let folderB = makePlainRepository("/tmp/prowl-sort-b")
    var state = RepositoriesFeature.State()
    state.repositories = [folderA, folderB]
    state.repositoryRoots = [folderA.location, folderB.location]
    state.sidebarLayout = SidebarLayout(repositoryIDs: [folderB.id, folderA.id])
    state.activeAgents.entries = [makeEntry(agentID(0), worktreeID: folderA.id)]

    state.activeAgents.sortOrder = .project
    state.refreshActiveAgentOrder()
    #expect(state.activeAgents.projectIDsByEntryID == [agentID(0): folderA.id])
    #expect(state.activeAgents.projectOrder == [folderB.id, folderA.id])

    state.activeAgents.sortOrder = .startTime
    state.refreshActiveAgentOrder()
    #expect(state.activeAgents.projectIDsByEntryID.isEmpty)
    #expect(state.activeAgents.projectOrder.isEmpty)
  }

  @Test func aNewAgentGetsItsProjectInProjectMode() async {
    let folder = makePlainRepository("/tmp/prowl-sort-a")
    var state = RepositoriesFeature.State()
    state.repositories = [folder]
    state.repositoryRoots = [folder.location]
    state.sidebarLayout = SidebarLayout(repositoryIDs: [folder.id])
    state.activeAgents.sortOrder = .project
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let entry = makeEntry(agentID(0), worktreeID: folder.id)

    await store.send(.activeAgents(.agentEntryChanged(entry, autoShowPanel: false))) {
      $0.activeAgents.entries = [entry]
      $0.activeAgents.projectIDsByEntryID = [agentID(0): folder.id]
      $0.activeAgents.projectOrder = [folder.id]
    }
  }

  @Test func orderInputsExistOnlyInProjectMode() {
    var state = RepositoriesFeature.State()
    #expect(state.activeAgentOrderInputs == nil)
    state.activeAgents.sortOrder = .project
    #expect(state.activeAgentOrderInputs != nil)
  }

  // MARK: - Helpers

  private func sections(
    _ entries: IdentifiedArrayOf<ActiveAgentEntry>,
    _ sortOrder: ActiveAgentsSortOrder
  ) -> [ActiveAgentSection] {
    ActiveAgentsOrdering.sections(entries: entries, sortOrder: sortOrder, projectIDs: [:], projectOrder: [])
  }

  private func makeEntries(_ states: [AgentDisplayState]) -> IdentifiedArrayOf<ActiveAgentEntry> {
    IdentifiedArray(
      uniqueElements: states.enumerated().map { index, state in
        makeEntry(agentID(UInt8(index)), state: state)
      })
  }

  private func makeEntry(
    _ id: UUID,
    worktreeID: Worktree.ID = "/repo/wt",
    workingDirectory: URL? = nil,
    state: AgentDisplayState = .idle
  ) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: id,
      worktreeID: worktreeID,
      worktreeName: "wt",
      workingDirectory: workingDirectory,
      tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: "1",
      surfaceID: id,
      paneIndex: 1,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
      agent: .codex,
      rawState: state == .blocked ? .blocked : state == .working ? .working : .idle,
      displayState: state,
      lastChangedAt: Date(timeIntervalSince1970: 10)
    )
  }

  private func makePlainRepository(_ path: String) -> Repository {
    let url = URL(fileURLWithPath: path)
    return Repository(
      id: path,
      location: .local(url),
      name: url.lastPathComponent,
      kind: .plain,
      worktrees: []
    )
  }
}

private func agentID(_ value: UInt8) -> UUID {
  UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
