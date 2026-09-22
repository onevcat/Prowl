import Foundation
import Testing

@testable import supacode

struct GitRepositoryProbeTests {
  @Test func realGitDistinguishesPlainLinkedBareAndBrokenMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try await GitExecutableResolver.shared.resolve()
    let client = GitClient(resolveGit: { _ in executable })
    do {
      _ = try await client.repoRoot(for: root)
      Issue.record("An empty directory is not a repository")
    } catch {
      #expect(RepositoriesFeature.isNotGitRepositoryError(error))
    }
    let main = root.appending(path: "main", directoryHint: .isDirectory)
    let linked = root.appending(path: "linked", directoryHint: .isDirectory)
    let bare = root.appending(path: "bare", directoryHint: .isDirectory)
    _ = try await executable.run(["init", "-q", main.path])
    _ = try await executable.run(
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgSign=false",
        "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Initial",
      ], in: main)
    _ = try await executable.run(["worktree", "add", "-b", "linked", linked.path], in: main)
    _ = try await executable.run(["init", "--bare", "-q", bare.path])
    for (directory, expected) in [(main, main), (linked, main), (bare, bare)] {
      let discovered = try await client.repoRoot(for: directory)
      #expect(RepositoriesFeature.pathsReferToSameFileSystemLocation(discovered.path, expected.path))
    }
    try Data("gitdir: /missing-prowl-test-metadata".utf8).write(to: linked.appending(path: ".git"))
    do {
      _ = try await client.repoRoot(for: linked)
      Issue.record("Broken metadata must fail discovery")
    } catch {
      #expect(!RepositoriesFeature.isNotGitRepositoryError(error))
    }
    let metadata = main.appending(path: ".git")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: metadata.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: metadata.path) }
    do {
      _ = try await client.repoRoot(for: main)
      Issue.record("Inaccessible metadata must fail discovery")
    } catch {
      #expect(!RepositoriesFeature.isNotGitRepositoryError(error))
    }
  }
}
