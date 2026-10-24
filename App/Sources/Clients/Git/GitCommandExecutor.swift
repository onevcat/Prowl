import Foundation

/// What `GitClient` runs its commands with (docs-ai 084 A5): a shell, the `git`
/// executable, and the bundled `wt` script. The local executor runs them on this
/// Mac; a repository on another host provides its own executor (B3).
nonisolated struct GitCommandExecutor: Sendable {
  let shell: ShellClient
  let resolveGit: @Sendable (_ revalidate: Bool) async throws -> GitExecutable
  let wtScriptURL: @Sendable () throws -> URL

  static let local = GitCommandExecutor(
    shell: .live,
    resolveGit: { try await GitExecutableResolver.shared.resolve(revalidate: $0) },
    wtScriptURL: bundledWtScriptURL
  )

  @Sendable static func bundledWtScriptURL() throws -> URL {
    guard let url = Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt") else {
      fatalError("Bundled wt script not found")
    }
    return url
  }
}
