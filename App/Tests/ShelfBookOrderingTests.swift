import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct ShelfBookOrderingTests {
  @Test func emptyRepositoriesProduceNoBooks() {
    let state = RepositoriesFeature.State()
    #expect(state.orderedShelfBooks().isEmpty)
  }

  @Test func unopenedWorktreesDoNotAppearOnShelf() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let main = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    // Empty `openedWorktreeIDs` → no spines even though the worktree
    // exists. The Shelf only shows interactive books.
    #expect(state.orderedShelfBooks().isEmpty)
  }

  @Test func singleWorktreeRepositoryProducesOneBookPerOpenedWorktree() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let main = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let feature = Worktree(
      id: "/tmp/repo/feature",
      name: "feature/login",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/feature"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    state.openedWorktreeIDs = [main.id, feature.id]

    let books = state.orderedShelfBooks()
    #expect(books.count == 2)
    #expect(books[0].id == main.id)
    #expect(books[0].kind == .worktree)
    #expect(books[0].displayName == "main")
    #expect(books[1].id == feature.id)
    #expect(books[1].kind == .worktree)
    #expect(books[1].displayName == "feature/login")
  }

  @Test func unopenedWorktreesInOpenedRepoAreFiltered() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let main = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let feature = Worktree(
      id: "/tmp/repo/feature",
      name: "feature/login",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/feature"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    state.openedWorktreeIDs = [feature.id]  // only feature has been opened

    let books = state.orderedShelfBooks()
    #expect(books.count == 1)
    #expect(books[0].id == feature.id)
  }

  @Test func plainFolderRepositoryProducesOnePlainFolderBook() {
    let rootURL = URL(fileURLWithPath: "/tmp/folder")
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    state.openedWorktreeIDs = [repository.id]

    let books = state.orderedShelfBooks()
    #expect(books.count == 1)
    #expect(books[0].id == repository.id)
    #expect(books[0].kind == .plainFolder)
    #expect(books[0].branchName == nil)
    #expect(books[0].displayName == "folder")
  }

  @Test func mixedRepositoriesPreserveOrder() {
    let gitRootURL = URL(fileURLWithPath: "/tmp/git")
    let gitMain = Worktree(
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
      worktrees: IdentifiedArray(uniqueElements: [gitMain])
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
    state.openedWorktreeIDs = [gitMain.id, plainRepo.id]

    let books = state.orderedShelfBooks()
    #expect(books.count == 2)
    #expect(books[0].id == gitMain.id)
    #expect(books[0].kind == .worktree)
    #expect(books[1].id == plainRepo.id)
    #expect(books[1].kind == .plainFolder)
  }

  @Test func openShelfBookIDFollowsSelectedWorktree() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
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

    #expect(state.openShelfBookID == worktree.id)
  }

  @Test func openShelfBookReturnsNilWhenSelectedBookIsNoLongerRendered() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    state.selection = .worktree(worktree.id)
    state.openedWorktreeIDs = []

    let books = state.orderedShelfBooks()
    #expect(books.isEmpty)
    #expect(state.openShelfBookID == worktree.id)
    #expect(state.openShelfBook(in: books) == nil)
  }

  @Test func openShelfBookIDResolvesPlainFolderViaRepositoryID() {
    let rootURL = URL(fileURLWithPath: "/tmp/plain")
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "plain",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.selection = .repository(repository.id)

    #expect(state.openShelfBookID == repository.id)
  }

  @Test func customTitleOverridesProjectNameForWorktreeBooks() {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let main = Worktree(
      id: "/tmp/repo",
      name: "main",
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    state.openedWorktreeIDs = [main.id]

    let books = state.orderedShelfBooks(customTitles: [repository.id: "My Custom Repo"])

    #expect(books.count == 1)
    #expect(books[0].projectName == "My Custom Repo")
    // Worktree's own displayName stays as the worktree branch — only
    // the repo-level project label is overridden.
    #expect(books[0].displayName == "main")
  }

  @Test func customTitleOverridesBothNamesForPlainFolderBook() {
    let rootURL = URL(fileURLWithPath: "/tmp/folder")
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    state.openedWorktreeIDs = [repository.id]

    let books = state.orderedShelfBooks(customTitles: [repository.id: "Plain Folder Alias"])

    #expect(books.count == 1)
    #expect(books[0].kind == .plainFolder)
    #expect(books[0].projectName == "Plain Folder Alias")
    #expect(books[0].displayName == "Plain Folder Alias")
  }

  @Test func missingCustomTitleFallsBackToRepositoryName() {
    let rootURL = URL(fileURLWithPath: "/tmp/folder")
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "folder",
      kind: .plain,
      worktrees: []
    )
    var state = RepositoriesFeature.State(repositories: [repository])
    state.repositoryRoots = [rootURL]
    state.repositoryOrderIDs = [repository.id]
    state.openedWorktreeIDs = [repository.id]

    let books = state.orderedShelfBooks(customTitles: [:])

    #expect(books.count == 1)
    #expect(books[0].projectName == "folder")
    #expect(books[0].displayName == "folder")
  }
}
