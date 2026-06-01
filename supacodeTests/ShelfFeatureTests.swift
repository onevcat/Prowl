import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

@MainActor
struct ShelfFeatureTests {
  @Test(.dependencies) func toggleShelfFromWorktreeEntersShelfWithoutRedirecting() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.toggleShelf) {
      $0.isShelfActive = true
      $0.openedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
    }
    await store.finish()
  }

  @Test(.dependencies) func toggleShelfWhileActiveExitsShelf() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.isShelfActive = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.toggleShelf) {
      $0.isShelfActive = false
    }
    await store.finish()
  }

  @Test(.dependencies) func toggleShelfWithoutWorktreesIsNoOp() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.toggleShelf)
    await store.finish()
  }

  @Test(.dependencies) func toggleShelfFromCanvasRedirectsToWorktreeAndEntersShelf() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .canvas
    state.lastFocusedWorktreeID = worktree.id
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.toggleShelf) {
      $0.isShelfActive = true
    }
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func toggleShelfFromCanvasPrefersCanvasFocusedCard() async {
    // Canvas can have a focused card distinct from `lastFocusedWorktreeID`
    // (which is only updated while `selection` is `.worktree`). A direct
    // Canvas → Shelf switch should open *that* card as the active book.
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktreeA = Worktree(
      id: "/tmp/repo/wt-a",
      name: "wt-a",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-a"),
      repositoryRootURL: rootURL
    )
    let worktreeB = Worktree(
      id: "/tmp/repo/wt-b",
      name: "wt-b",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-b"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktreeA, worktreeB])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .canvas
    state.lastFocusedWorktreeID = worktreeA.id
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { worktreeB.id }
    }

    await store.send(.toggleShelf) {
      $0.isShelfActive = true
    }
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktreeB.id)
      $0.sidebarSelectedWorktreeIDs = [worktreeB.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktreeB.id]
      $0.openedWorktreeIDs = [worktreeB.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func toggleShelfFromArchivedRedirectsToWorktreeAndEntersShelf() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .archivedWorktrees
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.toggleShelf) {
      $0.isShelfActive = true
    }
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.pendingTerminalFocusWorktreeIDs = [worktree.id]
      $0.openedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func selectingADifferentWorktreeKeepsShelfActive() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let first = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let second = Worktree(
      id: "/tmp/repo/wt2",
      name: "wt2",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt2"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [first, second])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(first.id)
    state.isShelfActive = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Mirrors "user clicks second worktree in the left navigation
    // while in Shelf mode": Shelf must not exit; only the open book
    // changes via the new `selectedWorktreeID`.
    await store.send(.selectWorktree(second.id, focusTerminal: true)) {
      $0.selection = .worktree(second.id)
      $0.sidebarSelectedWorktreeIDs = [second.id]
      $0.pendingTerminalFocusWorktreeIDs = [second.id]
      $0.openedWorktreeIDs = [second.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func selectCanvasClearsShelfActiveFlag() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.isShelfActive = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }

    await store.send(.selectCanvas) {
      $0.preCanvasWorktreeID = worktree.id
      $0.preCanvasTerminalTargetID = worktree.id
      $0.isShelfActive = false
      $0.selection = .canvas
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.finish()
  }

  @Test(.dependencies) func selectShelfBookByIndexDispatchesWorktreeSelection() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let wt2 = Worktree(
      id: "/tmp/repo/feature",
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/feature"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1, wt2])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repo.id]
    state.selection = .worktree(wt1.id)
    state.isShelfActive = true
    state.openedWorktreeIDs = [wt1.id, wt2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectShelfBook(2))
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func selectShelfBookOutOfRangeIsNoOp() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repo.id]
    state.selection = .worktree(wt1.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectShelfBook(5))
    await store.finish()
  }

  @Test(.dependencies) func selectNextShelfBookWrapsAround() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let wt2 = Worktree(
      id: "/tmp/repo/feature",
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/feature"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1, wt2])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repo.id]
    state.selection = .worktree(wt2.id)  // Currently on the last book.
    state.openedWorktreeIDs = [wt1.id, wt2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextShelfBook)
    // Wrapping: next-after-last lands back on the first book.
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func selectNextWorktreeRoutesToTabNavigationInShelf() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.selection = .worktree(wt1.id)
    state.isShelfActive = true
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.selectNextWorktree)
    await store.finish()
    #expect(sentCommands.value == [.performBindingAction(wt1, action: "next_tab")])
  }

  @Test(.dependencies) func selectPreviousWorktreeRoutesToTabNavigationInShelf() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.selection = .worktree(wt1.id)
    state.isShelfActive = true
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.selectPreviousWorktree)
    await store.finish()
    #expect(sentCommands.value == [.performBindingAction(wt1, action: "previous_tab")])
  }

  @Test(.dependencies) func worktreeHistoryIsUnavailableWhileShelfIsActive() async {
    let fixture = threeWorktreeFixture()
    var state = RepositoriesFeature.State(repositories: [fixture.repo])
    state.selection = .worktree(fixture.worktrees[1].id)
    state.isShelfActive = true
    state.worktreeHistoryBackStack = [fixture.worktrees[0].id]
    state.worktreeHistoryForwardStack = [fixture.worktrees[2].id]
    #expect(!state.canNavigateWorktreeHistoryBackward)
    #expect(!state.canNavigateWorktreeHistoryForward)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack)
    await store.send(.worktreeHistoryForward)
    await store.finish()
  }

  @Test(.dependencies) func worktreeHistoryIsUnavailableWhileCanvasIsActive() async {
    let fixture = threeWorktreeFixture()
    var state = RepositoriesFeature.State(repositories: [fixture.repo])
    state.selection = .canvas
    state.worktreeHistoryBackStack = [fixture.worktrees[0].id]
    state.worktreeHistoryForwardStack = [fixture.worktrees[2].id]
    #expect(!state.canNavigateWorktreeHistoryBackward)
    #expect(!state.canNavigateWorktreeHistoryForward)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack)
    await store.send(.worktreeHistoryForward)
    await store.finish()
  }

  @Test(.dependencies) func selectNextWorktreeOutsideShelfStillCyclesWorktrees() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let wt2 = Worktree(
      id: "/tmp/repo/wt2",
      name: "wt2",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt2"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1, wt2])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.selection = .worktree(wt1.id)
    // Shelf NOT active — existing worktree-cycling behavior must survive.
    state.isShelfActive = false
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.openedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func markWorktreeClosedRemovesFromOpenedSet() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.openedWorktreeIDs = [wt1.id]
    state.selection = nil  // Not currently selected, no auto-next needed.
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.markWorktreeClosed(wt1.id)) {
      $0.openedWorktreeIDs = []
    }
    await store.finish()
  }

  @Test(.dependencies) func markWorktreeClosedAdvancesToNextBookWhenAvailable() async {
    let fixture = threeWorktreeFixture()
    var state = RepositoriesFeature.State(repositories: [fixture.repo])
    state.repositoryRoots = [fixture.repo.rootURL]
    state.repositoryOrderIDs = [fixture.repo.id]
    state.selection = .worktree(fixture.worktrees[1].id)  // Middle book open.
    state.isShelfActive = true
    state.openedWorktreeIDs = Set(fixture.worktrees.map(\.id))
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Closing the middle book → replacement is the one AFTER it (wt3),
    // not the first book (wt1). The user stays close to where they
    // were on the shelf.
    let closingID = fixture.worktrees[1].id
    let nextID = fixture.worktrees[2].id
    await store.send(.markWorktreeClosed(closingID)) {
      $0.openedWorktreeIDs = [fixture.worktrees[0].id, nextID]
    }
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(nextID)
      $0.sidebarSelectedWorktreeIDs = [nextID]
      $0.pendingTerminalFocusWorktreeIDs = [nextID]
      $0.openedWorktreeIDs = [fixture.worktrees[0].id, nextID]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func markWorktreeClosedFallsBackToPreviousBookWhenClosingLast() async {
    let fixture = threeWorktreeFixture()
    var state = RepositoriesFeature.State(repositories: [fixture.repo])
    state.repositoryRoots = [fixture.repo.rootURL]
    state.repositoryOrderIDs = [fixture.repo.id]
    state.selection = .worktree(fixture.worktrees[2].id)  // Last book open.
    state.isShelfActive = true
    state.openedWorktreeIDs = Set(fixture.worktrees.map(\.id))
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Closing the last book → no book after it, so the replacement is
    // the book BEFORE it (wt2).
    let closingID = fixture.worktrees[2].id
    let prevID = fixture.worktrees[1].id
    await store.send(.markWorktreeClosed(closingID)) {
      $0.openedWorktreeIDs = [fixture.worktrees[0].id, prevID]
    }
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(prevID)
      $0.sidebarSelectedWorktreeIDs = [prevID]
      $0.pendingTerminalFocusWorktreeIDs = [prevID]
      $0.openedWorktreeIDs = [fixture.worktrees[0].id, prevID]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func markWorktreeClosedRemovesPlainFolderBookFromOpenedSet() async {
    // Plain-folder books live in `openedWorktreeIDs` under their
    // `Repository.ID`. The Shelf "Close Folder" menu dispatches
    // `.markWorktreeClosed(book.id)` for this path, so the reducer must
    // handle a plain-folder ID the same way it handles a worktree ID.
    let rootURL = URL(fileURLWithPath: "/tmp/folder")
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repo.id]
    state.selection = .repository(repo.id)
    state.isShelfActive = true
    state.openedWorktreeIDs = [repo.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Only book on the Shelf — closing it leaves the opened set empty
    // and produces no replacement selection, so the Shelf falls back to
    // the empty state.
    await store.send(.markWorktreeClosed(repo.id)) {
      $0.openedWorktreeIDs = []
    }
    await store.finish()
  }

  @Test(.dependencies) func markWorktreeClosedAdvancesToPlainFolderNeighbor() async {
    // Closing a worktree book whose neighbor is a plain folder must
    // route through the `.selectRepository` branch of
    // `shelfBookSelectionEffect`, not `.selectWorktree`. Covers the
    // plain-folder path of the replacement dispatch that the new
    // Shelf "Close Worktree/Folder" menu relies on.
    let gitRootURL = URL(fileURLWithPath: "/tmp/git")
    let worktree = Worktree(
      id: "/tmp/git",
      name: "main",
      detail: "",
      workingDirectory: gitRootURL,
      repositoryRootURL: gitRootURL
    )
    let gitRepo = Repository(
      id: gitRootURL.path(percentEncoded: false),
      rootURL: gitRootURL,
      name: "git",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    let plainRootURL = URL(fileURLWithPath: "/tmp/plain")
    let plainRepo = Repository(
      id: plainRootURL.path(percentEncoded: false),
      rootURL: plainRootURL,
      name: "plain",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [gitRepo, plainRepo])
    state.repositoryRoots = [gitRootURL, plainRootURL]
    state.repositoryOrderIDs = [gitRepo.id, plainRepo.id]
    state.selection = .worktree(worktree.id)
    state.isShelfActive = true
    state.openedWorktreeIDs = [worktree.id, plainRepo.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.markWorktreeClosed(worktree.id)) {
      $0.openedWorktreeIDs = [plainRepo.id]
    }
    await store.receive(\.selectRepository) {
      $0.selection = .repository(plainRepo.id)
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  private struct ThreeWorktreeFixture {
    let repo: Repository
    let worktrees: [Worktree]
  }

  private func threeWorktreeFixture() -> ThreeWorktreeFixture {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktrees = (1...3).map { index in
      Worktree(
        id: "/tmp/repo/wt\(index)",
        name: "wt\(index)",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt\(index)"),
        repositoryRootURL: rootURL
      )
    }
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    return ThreeWorktreeFixture(repo: repo, worktrees: worktrees)
  }

  @Test(.dependencies) func markWorktreeClosedLeavesSelectionAloneInNormalView() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let wt2 = Worktree(
      id: "/tmp/repo/wt2",
      name: "wt2",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt2"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1, wt2])
    )
    var state = RepositoriesFeature.State(repositories: [repo])
    state.selection = .worktree(wt1.id)
    state.isShelfActive = false  // Normal view.
    state.openedWorktreeIDs = [wt1.id, wt2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // In normal view, removing from the opened set must not also steal
    // selection away from the user — they are actively on wt1.
    await store.send(.markWorktreeClosed(wt1.id)) {
      $0.openedWorktreeIDs = [wt2.id]
    }
    await store.finish()
  }

  @Test(.dependencies) func markWorktreeOpenedAddsToOpenedSet() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let wt1 = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repo = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [wt1])
    )
    let store = TestStore(initialState: RepositoriesFeature.State(repositories: [repo])) {
      RepositoriesFeature()
    }

    // Mirrors the AppFeature forwarding `terminalEvent(.tabCreated)` →
    // `.markWorktreeOpened`. Any tab creation (including restored
    // layouts) adds its worktree to the Shelf's visible book set.
    await store.send(.markWorktreeOpened(wt1.id)) {
      $0.openedWorktreeIDs = [wt1.id]
    }
    await store.finish()
  }

  @Test(.dependencies) func selectArchivedWorktreesClearsShelfActiveFlag() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.isShelfActive = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectArchivedWorktrees) {
      $0.isShelfActive = false
      $0.worktreeHistoryBackStack = [worktree.id]
      $0.selection = .archivedWorktrees
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  @Test(.dependencies) func defaultViewShelfDefersDuringLayoutRestore() async {
    // When Layout Restore is active the snapshot-load hook must stay
    // quiet: Layout Restore clears selection and replays tabs, so
    // entering Shelf here would flash an empty open area and leave a
    // stray spine if the restored active book differs from
    // `lastFocusedWorktreeID`. The AppFeature hook on `.layoutRestored`
    // takes over once Layout Restore has settled.
    let repoRoot = "/tmp/default-shelf-restore-repo"
    let rootURL = URL(fileURLWithPath: repoRoot)
    let worktree = Worktree(
      id: "\(repoRoot)/main",
      name: "main",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "\(repoRoot)/main"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: repoRoot,
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )

    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      var updated = $0.global
      updated.defaultViewMode = .shelf
      $0.global = updated
    }
    defer {
      $settingsFile.withLock {
        var updated = $0.global
        updated.defaultViewMode = .normal
        $0.global = updated
      }
    }

    var initialState = RepositoriesFeature.State()
    initialState.lastFocusedWorktreeID = worktree.id
    initialState.shouldRestoreLastFocusedWorktree = true
    initialState.snapshotPersistencePhase = .restoring
    initialState.launchRestoreMode = .restoreLayout
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.repositorySnapshotLoaded([repository])) {
      $0.repositories = [repository]
      $0.repositoryRoots = [rootURL]
      $0.selection = .worktree(worktree.id)
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    // No `.toggleShelf` here — the Layout Restore path is responsible.
    await store.finish()
  }

  @Test(.dependencies) func defaultViewCanvasDefersDuringLayoutRestore() async {
    // Mirrors the Shelf deferral: during Layout Restore the snapshot-load
    // hook stays quiet and the AppFeature `.layoutRestored` path takes over.
    let repoRoot = "/tmp/default-canvas-restore-repo"
    let rootURL = URL(fileURLWithPath: repoRoot)
    let worktree = Worktree(
      id: "\(repoRoot)/main",
      name: "main",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "\(repoRoot)/main"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: repoRoot,
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )

    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      var updated = $0.global
      updated.defaultViewMode = .canvas
      $0.global = updated
    }
    defer {
      $settingsFile.withLock {
        var updated = $0.global
        updated.defaultViewMode = .normal
        $0.global = updated
      }
    }

    var initialState = RepositoriesFeature.State()
    initialState.lastFocusedWorktreeID = worktree.id
    initialState.shouldRestoreLastFocusedWorktree = true
    initialState.snapshotPersistencePhase = .restoring
    initialState.launchRestoreMode = .restoreLayout
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.repositorySnapshotLoaded([repository])) {
      $0.repositories = [repository]
      $0.repositoryRoots = [rootURL]
      $0.selection = .worktree(worktree.id)
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    // No `.toggleCanvas` here — the Layout Restore path is responsible.
    await store.finish()
  }

  @Test func isShowingShelfRequiresAtLeastOneRepository() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: []
    )

    // Active shelf with zero repositories falls back to Normal — covers the
    // zero-repo launch race where `isShelfActive` is flipped on (from the
    // repository snapshot) before the empty entries file reconciles repos
    // back to empty.
    var empty = RepositoriesFeature.State()
    empty.isShelfActive = true
    #expect(empty.repositories.isEmpty)
    #expect(empty.isShowingShelf == false)

    // With a repository present, the active shelf renders.
    var withRepo = RepositoriesFeature.State(repositories: [repository])
    withRepo.isShelfActive = true
    #expect(withRepo.isShowingShelf == true)

    // Inactive shelf is never showing.
    withRepo.isShelfActive = false
    #expect(withRepo.isShowingShelf == false)
  }
}
