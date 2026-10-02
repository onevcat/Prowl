import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct WorktreeDirectoryIndexTests {
  @Test func resolvesNestedDirectoryToItsEnclosingWorktree() {
    let worktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let index = WorktreeDirectoryIndex(repositories: [makeRepository(id: "/tmp/repo", worktrees: [worktree])])

    #expect(
      index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo/src/lib")) == worktree.id
    )
  }

  @Test func prefersTheDeepestContainingWorktree() {
    let mainWorktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let nestedWorktree = makeWorktree(
      repoRoot: "/tmp/repo",
      path: "/tmp/repo/worktrees/feature",
      branch: "feature"
    )
    let index = WorktreeDirectoryIndex(
      repositories: [makeRepository(id: "/tmp/repo", worktrees: [mainWorktree, nestedWorktree])]
    )

    #expect(
      index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo/worktrees/feature/lib"))
        == nestedWorktree.id
    )
    #expect(
      index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo/src")) == mainWorktree.id
    )
  }

  /// A sibling whose name merely starts with an indexed directory's name must not match. This is why
  /// the index compares whole path components rather than raw string prefixes.
  @Test func doesNotMatchSiblingDirectoryWithSharedNamePrefix() {
    let worktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let index = WorktreeDirectoryIndex(repositories: [makeRepository(id: "/tmp/repo", worktrees: [worktree])])

    #expect(index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo2/src")) == nil)
    #expect(index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo-backup")) == nil)
  }

  @Test func resolvesPlainFolderRepositoryByItsRootURL() {
    let repository = makeRepository(id: "/tmp/notes", kind: .plain, worktrees: [])
    let index = WorktreeDirectoryIndex(repositories: [repository])

    #expect(
      index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/notes/inbox")) == repository.id
    )
  }

  @Test func returnsNilForDirectoryOutsideEveryRepository() {
    let worktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let index = WorktreeDirectoryIndex(repositories: [makeRepository(id: "/tmp/repo", worktrees: [worktree])])

    #expect(index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/scratch")) == nil)
  }

  @Test func emptyIndexResolvesNothing() {
    let index = WorktreeDirectoryIndex()

    #expect(index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo")) == nil)
  }

  /// Trailing slashes and `.` / `..` segments must normalize to the same lookup.
  @Test func normalizesRelativeSegmentsBeforeMatching() {
    let worktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let index = WorktreeDirectoryIndex(repositories: [makeRepository(id: "/tmp/repo", worktrees: [worktree])])

    #expect(
      index.worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo/src/../lib")) == worktree.id
    )
  }

  // MARK: - Cache

  @Test func cacheRebuildsWhenAWorktreeIsAdded() {
    WorktreeDirectoryIndexCache.reset()
    let mainWorktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let before: IdentifiedArrayOf<Repository> = [makeRepository(id: "/tmp/repo", worktrees: [mainWorktree])]
    #expect(
      WorktreeDirectoryIndexCache.index(for: before)
        .worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo/worktrees/feature/lib"))
        == mainWorktree.id
    )

    let nestedWorktree = makeWorktree(
      repoRoot: "/tmp/repo",
      path: "/tmp/repo/worktrees/feature",
      branch: "feature"
    )
    let after: IdentifiedArrayOf<Repository> = [
      makeRepository(id: "/tmp/repo", worktrees: [mainWorktree, nestedWorktree])
    ]

    #expect(
      WorktreeDirectoryIndexCache.index(for: after)
        .worktreeID(forWorkingDirectory: URL(fileURLWithPath: "/tmp/repo/worktrees/feature/lib"))
        == nestedWorktree.id
    )
  }

  /// A branch rename changes the worktree's name but not its directory, so the memo stays valid.
  @Test func cacheReturnsAnEquivalentIndexWhenOnlyBranchNamesChange() {
    WorktreeDirectoryIndexCache.reset()
    let original = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let renamed = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "trunk")
    let first = WorktreeDirectoryIndexCache.index(for: [makeRepository(id: "/tmp/repo", worktrees: [original])])
    let second = WorktreeDirectoryIndexCache.index(for: [makeRepository(id: "/tmp/repo", worktrees: [renamed])])

    #expect(first == second)
  }

  @Test func cacheRevalidatesCanonicalPathsAfterInterval() throws {
    WorktreeDirectoryIndexCache.reset()
    let tempRoot = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let firstTarget = tempRoot.appending(path: "first", directoryHint: .isDirectory)
    let secondTarget = tempRoot.appending(path: "second", directoryHint: .isDirectory)
    let symlink = tempRoot.appending(path: "current", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: firstTarget)

    let repository = makeRepository(
      id: symlink.path(percentEncoded: false),
      kind: .plain,
      worktrees: []
    )
    let start = ContinuousClock.now
    let first = WorktreeDirectoryIndexCache.index(for: [repository], now: start)
    #expect(first.worktreeID(forWorkingDirectory: firstTarget) == repository.id)

    try FileManager.default.removeItem(at: symlink)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secondTarget)

    let revalidated = WorktreeDirectoryIndexCache.index(
      for: [repository],
      now: start.advanced(by: .seconds(1))
    )
    #expect(revalidated.worktreeID(forWorkingDirectory: secondTarget) == repository.id)
    #expect(revalidated.worktreeID(forWorkingDirectory: firstTarget) == nil)
  }

  // MARK: - Resolution memo

  /// Proves the memo by making recomputation impossible to reproduce: the symlink the first
  /// lookup resolved through is deleted, so a fresh resolution would no longer reach the worktree.
  /// An answer that survives that can only have come from the memo.
  @Test func repeatedLookupIsServedFromTheMemo() throws {
    let fixture = try SymlinkedWorktreeFixture()
    defer { fixture.cleanUp() }
    WorktreeDirectoryIndexCache.reset()
    // Both lookups sit inside one revalidation interval, which is where the memo applies.
    let start = ContinuousClock.now

    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: fixture.queryThroughSymlink,
        in: fixture.repositories,
        now: start
      ) == fixture.worktreeID
    )

    try fixture.removeSymlink()

    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: fixture.queryThroughSymlink,
        in: fixture.repositories,
        now: start.advanced(by: .milliseconds(16))
      ) == fixture.worktreeID,
      "The symlink is gone, so only a memoized answer can still resolve"
    )

    // And the memo is the only reason: dropping it must recompute, which now finds nothing.
    WorktreeDirectoryIndexCache.reset()
    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: fixture.queryThroughSymlink,
        in: fixture.repositories,
        now: start.advanced(by: .milliseconds(32))
      ) == nil
    )
  }

  /// A resolution is only valid against the index that produced it, so changing the repository
  /// set must not leave an answer computed against the previous one.
  @Test func memoIsDroppedWhenTheRepositorySetChanges() {
    WorktreeDirectoryIndexCache.reset()
    let mainWorktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let nested = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo/worktrees/feature", branch: "feature")
    let directory = URL(fileURLWithPath: "/tmp/repo/worktrees/feature/lib")
    let start = ContinuousClock.now

    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: directory,
        in: [makeRepository(id: "/tmp/repo", worktrees: [mainWorktree])],
        now: start
      ) == mainWorktree.id
    )
    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: directory,
        in: [makeRepository(id: "/tmp/repo", worktrees: [mainWorktree, nested])],
        now: start.advanced(by: .milliseconds(16))
      ) == nested.id,
      "A stale memo would still report the main worktree"
    )
  }

  /// A memoized resolution normalizes the directory it was asked about, so it can go stale the same
  /// way the index can. It must not outlive the revalidation that exists to catch exactly that.
  @Test func memoIsDroppedWhenCanonicalPathsAreRevalidated() throws {
    let fixture = try SymlinkedWorktreeFixture()
    defer { fixture.cleanUp() }
    WorktreeDirectoryIndexCache.reset()
    let start = ContinuousClock.now

    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: fixture.queryThroughSymlink,
        in: fixture.repositories,
        now: start
      ) == fixture.worktreeID
    )

    try fixture.removeSymlink()

    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: fixture.queryThroughSymlink,
        in: fixture.repositories,
        now: start.advanced(by: .seconds(1))
      ) == nil,
      "Past the revalidation interval the answer must be recomputed, and it no longer resolves"
    )
  }

  /// The Active Agents overlay resolves every visible row as one render batch. The cache API
  /// should validate the repository signature once for that batch, then reuse the resulting
  /// index and resolution memo for every distinct directory.
  @Test func batchLookupResolvesAllDirectories() {
    WorktreeDirectoryIndexCache.reset()
    let mainWorktree = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo", branch: "main")
    let nested = makeWorktree(repoRoot: "/tmp/repo", path: "/tmp/repo/worktrees/feature", branch: "feature")
    let repositories: IdentifiedArrayOf<Repository> = [
      makeRepository(id: "/tmp/repo", worktrees: [mainWorktree, nested])
    ]
    let mainDirectory = URL(fileURLWithPath: "/tmp/repo/Sources")
    let nestedDirectory = URL(fileURLWithPath: "/tmp/repo/worktrees/feature/Tests")
    let outsideDirectory = URL(fileURLWithPath: "/tmp/elsewhere")

    let resolved = WorktreeDirectoryIndexCache.worktreeIDs(
      forWorkingDirectories: [mainDirectory, nestedDirectory, outsideDirectory, nestedDirectory],
      in: repositories
    )

    #expect(resolved[mainDirectory] == mainWorktree.id)
    #expect(resolved[nestedDirectory] == nested.id)
    #expect(resolved[outsideDirectory] == nil)
  }

  /// A pane can `cd` anywhere, so the memo must not grow without bound.
  @Test func memoIsBoundedAndEvictsOldEntries() throws {
    let fixture = try SymlinkedWorktreeFixture()
    defer { fixture.cleanUp() }
    WorktreeDirectoryIndexCache.reset()
    // Held at one instant so revalidation never fires, leaving the cap as the only thing that can
    // drop the entry.
    let start = ContinuousClock.now

    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: fixture.queryThroughSymlink,
        in: fixture.repositories,
        now: start
      ) == fixture.worktreeID
    )
    try fixture.removeSymlink()

    // Flood past the cap with directories that resolve to nothing.
    for offset in 0..<300 {
      _ = WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: URL(fileURLWithPath: "/tmp/flood-\(offset)"),
        in: fixture.repositories,
        now: start
      )
    }

    #expect(
      WorktreeDirectoryIndexCache.worktreeID(
        forWorkingDirectory: fixture.queryThroughSymlink,
        in: fixture.repositories,
        now: start
      ) == nil,
      "The original entry should have been evicted and recomputed"
    )
  }

  // MARK: - Helpers

  /// A real worktree directory plus a symlink pointing at it, so a test can revoke the symlink and
  /// observe whether a later lookup recomputed or replayed.
  private struct SymlinkedWorktreeFixture {
    let root: URL
    let repositories: IdentifiedArrayOf<Repository>
    let worktreeID: Worktree.ID
    let queryThroughSymlink: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "prowl-directory-memo-\(UUID().uuidString)", directoryHint: .isDirectory)
      let real = root.appending(path: "real", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: real.appending(path: "sub", directoryHint: .isDirectory),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        at: root.appending(path: "link", directoryHint: .isDirectory),
        withDestinationURL: real
      )
      let worktree = Worktree(
        id: real.path,
        name: "main",
        detail: "main",
        workingDirectory: real,
        repositoryRootURL: real
      )
      worktreeID = worktree.id
      repositories = [
        Repository(id: real.path, rootURL: real, name: "real", kind: .git, worktrees: [worktree])
      ]
      queryThroughSymlink = root.appending(path: "link/sub", directoryHint: .isDirectory)
    }

    func removeSymlink() throws {
      try FileManager.default.removeItem(at: root.appending(path: "link", directoryHint: .isDirectory))
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
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
    kind: Repository.Kind = .git,
    worktrees: IdentifiedArrayOf<Worktree>
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      kind: kind,
      worktrees: worktrees
    )
  }
}
