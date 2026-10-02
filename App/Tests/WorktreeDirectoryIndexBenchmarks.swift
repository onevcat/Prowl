import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

extension PerformanceBenchmarks {
  /// Pins the #648/#655 directory index against the pre-#648 shape it replaced:
  /// every agent row scanning every worktree, with `PathPolicy` normalizing both
  /// sides of each containment test — filesystem round-trips per (row, worktree)
  /// pair. The index normalizes each worktree once at build time and each query
  /// once at lookup, so even the worst case (build plus a full query batch)
  /// must beat one naive batch.
  @Suite
  struct WorktreeDirectoryIndexBenchmarks {
    @Test func indexBuildPlusQueryBatchOutpacesThePerRowScan() throws {
      let fileManager = FileManager.default
      let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? fileManager.removeItem(at: tempRoot) }

      let repositoryCount = BenchmarkMeasurement.isFullMode ? 6 : 3
      let worktreesPerRepository = 4
      var repositories: IdentifiedArrayOf<Repository> = []
      var queries: [URL] = []
      for repositoryIndex in 0..<repositoryCount {
        let repoRoot = tempRoot.appending(path: "repo\(repositoryIndex)")
        var worktrees: IdentifiedArrayOf<Worktree> = []
        for worktreeIndex in 0..<worktreesPerRepository {
          let directory = repoRoot.appending(path: "wt\(worktreeIndex)")
          // Real directories, because `PathPolicy.normalizeURL` only pays its
          // symlink walk for paths that exist — the cost being benchmarked.
          let nested = directory.appending(path: "src/lib")
          try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
          worktrees.append(
            Worktree(
              id: directory.path,
              name: "wt\(worktreeIndex)",
              detail: "wt\(worktreeIndex)",
              workingDirectory: directory,
              repositoryRootURL: repoRoot
            )
          )
          queries.append(nested)
        }
        repositories.append(
          Repository(
            id: repoRoot.path,
            rootURL: repoRoot,
            name: repoRoot.lastPathComponent,
            kind: .git,
            worktrees: worktrees
          )
        )
      }
      queries.append(tempRoot.appending(path: "outside"))

      let allWorktrees = repositories.flatMap(\.worktrees)
      let index = WorktreeDirectoryIndex(repositories: repositories)
      for query in queries {
        #expect(index.worktreeID(forWorkingDirectory: query) == Self.referenceResolve(query, in: allWorktrees))
      }

      let medians = BenchmarkMeasurement.interleavedMedians(
        reference: {
          for query in queries {
            _ = Self.referenceResolve(query, in: allWorktrees)
          }
        },
        shipped: {
          // Rebuilding per round is the index's worst case; steady state reuses
          // the built index through `WorktreeDirectoryIndexCache` and is
          // strictly cheaper than what is measured here.
          let index = WorktreeDirectoryIndex(repositories: repositories)
          for query in queries {
            _ = index.worktreeID(forWorkingDirectory: query)
          }
        }
      )
      BenchmarkMeasurement.report(suite: "WorktreeDirectoryIndex", name: "build-plus-batch", medians: medians)
      #expect(
        BenchmarkMeasurement.ratio(medians) >= 2,
        "index build plus batch was only \(BenchmarkMeasurement.ratio(medians))x the per-row scan"
      )
    }

    /// The pre-#648 resolution shape: every query walks every worktree, and each
    /// containment test normalizes both sides again via `PathPolicy`.
    private static func referenceResolve(_ query: URL, in worktrees: [Worktree]) -> Worktree.ID? {
      var best: (id: Worktree.ID, depth: Int)?
      for worktree in worktrees where PathPolicy.contains(query, in: worktree.workingDirectory) {
        let depth = PathPolicy.normalizeURL(worktree.workingDirectory).pathComponents.count
        if depth > (best?.depth ?? -1) {
          best = (worktree.id, depth)
        }
      }
      return best?.id
    }
  }
}
