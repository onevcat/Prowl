import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct RepositorySectionViewTests {
  @Test func sidebarHeaderActionCollapsesWhenAnyExpandableRepositoryIsOpen() {
    let gitRepository = Repository(
      id: "/tmp/git",
      rootURL: URL(fileURLWithPath: "/tmp/git"),
      name: "git",
      kind: .git,
      worktrees: []
    )
    let plainRepository = Repository(
      id: "/tmp/plain",
      rootURL: URL(fileURLWithPath: "/tmp/plain"),
      name: "plain",
      kind: .plain,
      worktrees: []
    )
    let expandableIDs = SidebarListView.expandableRepositoryIDs(
      in: [gitRepository, plainRepository]
    )

    #expect(expandableIDs == [gitRepository.id])
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [],
        expandableRepositoryIDs: [],
        activeRepositoryIDs: []
      )
        == .expandAll
    )
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: []
      )
        == .expandAll
    )
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [gitRepository.id],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: []
      )
        == .collapseAll
    )
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [gitRepository.id, plainRepository.id],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: []
      )
        == .collapseAll
    )
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [plainRepository.id],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: []
      )
        == .expandAll
    )
  }

  @Test func sidebarHeaderActionCyclesThroughExpandActive() {
    let repoA: Repository.ID = "/tmp/a"
    let repoB: Repository.ID = "/tmp/b"
    let expandableIDs: Set<Repository.ID> = [repoA, repoB]
    let activeIDs: Set<Repository.ID> = [repoA]

    // Fully collapsed + proper-subset active set → Expand Active.
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: activeIDs
      )
        == .expandActive
    )
    // Expanded set matches the active set exactly → Expand All.
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [repoA],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: activeIDs
      )
        == .expandAll
    )
    // Fully expanded → Collapse All.
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: expandableIDs,
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: activeIDs
      )
        == .collapseAll
    )
    // Mixed state different from the active set → Collapse All.
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [repoB],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: activeIDs
      )
        == .collapseAll
    )
    // Active set covering every expandable repo degrades to the plain
    // two-state cycle: Expand All from collapsed, Collapse All from expanded.
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: [],
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: expandableIDs
      )
        == .expandAll
    )
    #expect(
      SidebarListView.repositoryListHeaderAction(
        expandedRepoIDs: expandableIDs,
        expandableRepositoryIDs: expandableIDs,
        activeRepositoryIDs: expandableIDs
      )
        == .collapseAll
    )
  }

  @Test func activeRepositoryIDsIncludesOnlyExpandableReposWithOpenTabs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let busyWorktree = makeWorktree(repoRoot: "/tmp/busy", path: "/tmp/busy/main", branch: "main")
    let busyRepository = makeRepository(
      id: "/tmp/busy",
      name: "busy",
      worktrees: [busyWorktree]
    )
    let idleRepository = makeRepository(
      id: "/tmp/idle",
      name: "idle",
      worktrees: [makeWorktree(repoRoot: "/tmp/idle", path: "/tmp/idle/main", branch: "main")]
    )
    // Plain folder with a tab: not expandable, so never part of the active set.
    let plainRepository = makeRepository(
      id: "/tmp/plain",
      name: "plain",
      kind: .plain,
      worktrees: []
    )
    let repositories: IdentifiedArrayOf<Repository> = [
      busyRepository, idleRepository, plainRepository,
    ]
    let expandableIDs = SidebarListView.expandableRepositoryIDs(in: repositories)

    _ = manager.state(for: busyWorktree).tabManager.createTab(title: "work", icon: nil)
    let plainTarget = Worktree(
      id: plainRepository.id,
      name: plainRepository.name,
      detail: plainRepository.rootURL.path(percentEncoded: false),
      workingDirectory: plainRepository.rootURL,
      repositoryRootURL: plainRepository.rootURL
    )
    _ = manager.state(for: plainTarget).tabManager.createTab(title: "folder", icon: nil)

    #expect(
      SidebarListView.activeRepositoryIDs(
        in: repositories,
        expandableRepositoryIDs: expandableIDs,
        terminalManager: manager
      )
        == [busyRepository.id]
    )
  }

  @Test func explicitSelectionIncludesPrimarySelectedWorktree() {
    let worktree = Worktree(
      id: "/tmp/repo/wt",
      name: "wt",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      kind: .git,
      worktrees: [worktree]
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.selection = .worktree(worktree.id)

    #expect(SidebarListView.selectedWorktreeIDs(in: state) == [worktree.id])
  }

  @Test func repositoryHeaderDoesNotOpenCanvasTargetForExpandableGitRepositories() {
    let gitRepository = Repository(
      id: "/tmp/git",
      rootURL: URL(fileURLWithPath: "/tmp/git"),
      name: "git",
      kind: .git,
      worktrees: []
    )
    let plainRepository = Repository(
      id: "/tmp/plain",
      rootURL: URL(fileURLWithPath: "/tmp/plain"),
      name: "plain",
      kind: .plain,
      worktrees: []
    )

    #expect(!SidebarListView.repositoryHeaderOpensCanvasTarget(gitRepository))
    #expect(SidebarListView.repositoryHeaderOpensCanvasTarget(plainRepository))
  }

  @Test func activeAgentWorktreeMetadataUsesCustomRepositoryTitleAndCurrentBranchName() {
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/prowl")
    let worktree = Worktree(
      id: "/tmp/prowl/worktrees/active-agents",
      name: "feat/active-agents-panel",
      detail: "active-agents",
      workingDirectory: URL(fileURLWithPath: "/tmp/prowl/worktrees/active-agents"),
      repositoryRootURL: repositoryRootURL
    )
    let repository = Repository(
      id: "/tmp/prowl",
      rootURL: repositoryRootURL,
      name: "supacode",
      kind: .git,
      worktrees: [worktree]
    )

    let metadata = SidebarListView.activeAgentWorktreeMetadata(
      repositories: [repository],
      customTitles: [repository.id: "Prowl"],
      repositoryAppearances: [repository.id: RepositoryAppearance(color: .blue)]
    )

    #expect(metadata.repositoryNamesByWorktreeID[worktree.id] == "Prowl")
    #expect(metadata.branchNamesByWorktreeID[worktree.id] == "feat/active-agents-panel")
    #expect(metadata.repositoryColorsByWorktreeID[worktree.id] == .blue)
  }

  @Test func activeAgentWorktreeMetadataFallsBackToRepositoryNameForPlainFolders() {
    let repository = Repository(
      id: "/tmp/plain",
      rootURL: URL(fileURLWithPath: "/tmp/plain"),
      name: "plain",
      kind: .plain,
      worktrees: []
    )

    let metadata = SidebarListView.activeAgentWorktreeMetadata(
      repositories: [repository],
      customTitles: [:]
    )

    #expect(metadata.repositoryNamesByWorktreeID[repository.id] == "plain")
    #expect(metadata.branchNamesByWorktreeID[repository.id] == "plain")
    #expect(metadata.repositoryColorsByWorktreeID[repository.id] == nil)
  }

  // MARK: - Active agent row display (cwd-based repository/branch resolution)

  @Test func activeAgentRowDisplayUsesWorkingDirectoryRepositoryNotTabWorktree() {
    // The agent's tab physically lives in `tabRepo`, but it was launched after `cd`-ing into a
    // different checked-out repository. The row must reflect where the agent actually runs.
    let tabWorktree = makeWorktree(repoRoot: "/tmp/tab-repo", path: "/tmp/tab-repo", branch: "main")
    let tabRepo = makeRepository(id: "/tmp/tab-repo", name: "tab-repo", worktrees: [tabWorktree])
    let agentWorktree = makeWorktree(
      repoRoot: "/tmp/other-repo",
      path: "/tmp/other-repo",
      branch: "feature/login"
    )
    let agentRepo = makeRepository(id: "/tmp/other-repo", name: "other-repo", worktrees: [agentWorktree])
    let repositories: IdentifiedArrayOf<Repository> = [tabRepo, agentRepo]
    let metadata = SidebarListView.activeAgentWorktreeMetadata(
      repositories: repositories,
      customTitles: [:]
    )

    let entry = makeAgentEntry(
      worktreeID: tabWorktree.id,
      worktreeName: tabWorktree.name,
      // A nested sub-directory still resolves to the enclosing worktree.
      workingDirectory: URL(fileURLWithPath: "/tmp/other-repo/src")
    )
    let display = SidebarListView.activeAgentRowDisplay(
      for: entry,
      repositories: repositories,
      metadata: metadata
    )

    #expect(display.repositoryName == "other-repo")
    #expect(display.branchName == "feature/login")
  }

  @Test func activeAgentRowDisplayPrefersDeepestMatchingWorktree() {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(repoRoot: repoRoot, path: "/tmp/repo", branch: "main")
    // A worktree nested inside the repo root; the deepest containing directory must win.
    let nestedWorktree = makeWorktree(
      repoRoot: repoRoot,
      path: "/tmp/repo/worktrees/feature",
      branch: "feature"
    )
    let repository = makeRepository(
      id: repoRoot,
      name: "repo",
      worktrees: [mainWorktree, nestedWorktree]
    )
    let metadata = SidebarListView.activeAgentWorktreeMetadata(repositories: [repository], customTitles: [:])

    let key = SidebarListView.resolveWorktreeID(
      forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo/worktrees/feature/lib"),
      in: [repository]
    )

    #expect(key == nestedWorktree.id)
    let entry = makeAgentEntry(
      worktreeID: mainWorktree.id,
      worktreeName: mainWorktree.name,
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktrees/feature/lib")
    )
    let display = SidebarListView.activeAgentRowDisplay(for: entry, repositories: [repository], metadata: metadata)
    #expect(display.branchName == "feature")
  }

  @Test func activeAgentRowDisplayResolvesPlainFolderByRootURL() {
    let repository = makeRepository(id: "/tmp/notes", name: "notes", kind: .plain, worktrees: [])
    let metadata = SidebarListView.activeAgentWorktreeMetadata(repositories: [repository], customTitles: [:])

    let entry = makeAgentEntry(
      worktreeID: repository.id,
      worktreeName: repository.name,
      workingDirectory: URL(fileURLWithPath: "/tmp/notes/inbox")
    )
    let display = SidebarListView.activeAgentRowDisplay(for: entry, repositories: [repository], metadata: metadata)

    #expect(display.repositoryName == "notes")
    #expect(display.branchName == "notes")
  }

  @Test func activeAgentRowDisplayFallsBackToPathComponentForUnknownDirectory() {
    let tabWorktree = makeWorktree(repoRoot: "/tmp/tab-repo", path: "/tmp/tab-repo", branch: "main")
    let tabRepo = makeRepository(id: "/tmp/tab-repo", name: "tab-repo", worktrees: [tabWorktree])
    let metadata = SidebarListView.activeAgentWorktreeMetadata(repositories: [tabRepo], customTitles: [:])

    let entry = makeAgentEntry(
      worktreeID: tabWorktree.id,
      worktreeName: tabWorktree.name,
      workingDirectory: URL(fileURLWithPath: "/tmp/scratch/playground")
    )
    let display = SidebarListView.activeAgentRowDisplay(for: entry, repositories: [tabRepo], metadata: metadata)

    #expect(display.repositoryName == "playground")
    #expect(display.branchName == "playground")
    #expect(display.color == nil)
  }

  @Test func activeAgentRowDisplayFallsBackToOwningWorktreeWhenDirectoryUnknown() {
    let tabWorktree = makeWorktree(repoRoot: "/tmp/tab-repo", path: "/tmp/tab-repo", branch: "main")
    let tabRepo = makeRepository(id: "/tmp/tab-repo", name: "tab-repo", worktrees: [tabWorktree])
    let metadata = SidebarListView.activeAgentWorktreeMetadata(repositories: [tabRepo], customTitles: [:])

    let entry = makeAgentEntry(
      worktreeID: tabWorktree.id,
      worktreeName: tabWorktree.name,
      workingDirectory: nil
    )
    let display = SidebarListView.activeAgentRowDisplay(for: entry, repositories: [tabRepo], metadata: metadata)

    #expect(display.repositoryName == "tab-repo")
    #expect(display.branchName == "main")
  }

  private func makeWorktree(repoRoot: String, path: String, branch: String) -> Worktree {
    Worktree(
      id: path,
      name: branch,
      detail: branch,
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(
    id: String,
    name: String,
    kind: Repository.Kind = .git,
    worktrees: IdentifiedArrayOf<Worktree>
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      kind: kind,
      worktrees: worktrees
    )
  }

  private func makeAgentEntry(
    worktreeID: Worktree.ID,
    worktreeName: String,
    workingDirectory: URL?
  ) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: UUID(),
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      workingDirectory: workingDirectory,
      tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: "agent",
      surfaceID: UUID(),
      paneIndex: 1,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
      agent: .codex,
      rawState: .working,
      displayState: .working,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )
  }

  @Test func openTabCountForGitRepositorySumsAllWorktrees() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/repo")
    let mainWorktree = Worktree(
      id: "/tmp/repo/main",
      name: "main",
      detail: "main",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/main"),
      repositoryRootURL: repositoryRootURL
    )
    let featureWorktree = Worktree(
      id: "/tmp/repo/feature",
      name: "feature",
      detail: "feature",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/feature"),
      repositoryRootURL: repositoryRootURL
    )
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: repositoryRootURL,
      name: "repo",
      kind: .git,
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, featureWorktree])
    )

    let mainState = manager.state(for: mainWorktree)
    let featureState = manager.state(for: featureWorktree)
    _ = mainState.tabManager.createTab(title: "main 1", icon: nil)
    _ = mainState.tabManager.createTab(title: "main 2", icon: nil)
    _ = featureState.tabManager.createTab(title: "feature 1", icon: nil)

    #expect(
      RepositorySectionView.openTabCount(for: repository, terminalManager: manager)
        == 3
    )
  }

  @Test func openTabCountForPlainFolderUsesRepositoryIDTerminalState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/folder")
    let repository = Repository(
      id: "/tmp/folder",
      rootURL: repositoryRootURL,
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    let terminalTarget = Worktree(
      id: repository.id,
      name: repository.name,
      detail: repository.rootURL.path(percentEncoded: false),
      workingDirectory: repository.rootURL,
      repositoryRootURL: repository.rootURL
    )

    let state = manager.state(for: terminalTarget)
    _ = state.tabManager.createTab(title: "folder 1", icon: nil)
    _ = state.tabManager.createTab(title: "folder 2", icon: nil)

    #expect(
      RepositorySectionView.openTabCount(for: repository, terminalManager: manager)
        == 2
    )
  }
}
