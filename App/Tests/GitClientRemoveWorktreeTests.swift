import Foundation
import Testing

@testable import supacode

struct GitClientRemoveWorktreeTests {
  @Test func removeWorktreeDoesNotDeleteMainBranch() async throws {
    let store = ShellCallStore()
    let worktreePath = FileManager.default.temporaryDirectory
      .appending(path: "prowl-repo-main-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(worktreePath)\nHEAD abc\nbranch refs/heads/main\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "main\nfeature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktree = Worktree(
      id: worktreePath,
      name: "main",
      detail: "../repo-main-copy",
      workingDirectory: URL(fileURLWithPath: worktreePath),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: true)

    let calls = await store.calls
    #expect(calls.contains { $0.contains("worktree") && $0.contains("remove") })
    #expect(calls.contains { $0.contains("for-each-ref") })
    #expect(!calls.contains { $0.suffix(3) == ["branch", "-d", "main"] })
    #expect(!calls.contains { $0.suffix(3) == ["branch", "-D", "main"] })
  }

  @Test func removeWorktreeDeletesNonProtectedLocalBranchWhenRequested() async throws {
    let store = ShellCallStore()
    let worktreePath = FileManager.default.temporaryDirectory
      .appending(path: "prowl-repo-feature-\(UUID().uuidString)", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(worktreePath)\nHEAD abc\nbranch refs/heads/feature\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "main\nfeature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktree = Worktree(
      id: worktreePath,
      name: "feature",
      detail: "../repo-feature",
      workingDirectory: URL(fileURLWithPath: worktreePath),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: true)

    let calls = await store.calls
    #expect(calls.contains { $0.suffix(3) == ["branch", "-d", "feature"] })
  }

  @Test func removeWorktreeFailsWithoutMovingDirectoryWhenPathIsNotRegisteredExactly() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: "prowl-remove-worktree-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let parentURL = rootURL.appending(path: ".worktrees/feat", directoryHint: .isDirectory)
    let childURL = parentURL.appending(path: "foo", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: childURL, withIntermediateDirectories: true)
    try Data("gitdir: ../../.git/worktrees/foo\n".utf8).write(to: childURL.appending(path: ".git"))
    defer {
      try? fileManager.removeItem(at: rootURL)
    }

    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(childURL.path(percentEncoded: false))\nHEAD abc\nbranch refs/heads/feat/foo\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "feat\nfeat/foo\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktree = Worktree(
      id: parentURL.path(percentEncoded: false),
      name: "feat",
      detail: ".worktrees/feat",
      workingDirectory: parentURL,
      repositoryRootURL: rootURL
    )

    await #expect(throws: GitClientError.self) {
      _ = try await client.removeWorktree(worktree, deleteBranch: true)
    }

    let parentExists = fileManager.fileExists(atPath: parentURL.path(percentEncoded: false))
    let childExists = fileManager.fileExists(atPath: childURL.path(percentEncoded: false))
    #expect(parentExists)
    #expect(childExists)
    let calls = await store.calls
    #expect(!calls.contains { $0.contains("prune") })
    #expect(!calls.contains { $0.contains("remove") })
    #expect(!calls.contains { $0.suffix(3) == ["branch", "-d", "feat"] })
  }

  @Test func removeWorktreeMatchesWhenGitReportsPrivateSymlinkPath() async throws {
    // Regression: externally-created worktrees under /tmp are reported by git as `/private/tmp/...`,
    // but Prowl tracks them as standardized `/tmp/...` URLs. The removal guard must treat them as
    // the same worktree, otherwise removal silently no-ops and the row reappears after a refresh.
    let fileManager = FileManager.default
    let name = "prowl-private-symlink-wt-\(UUID().uuidString)"
    let standardizedURL = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
    try fileManager.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
    try Data("gitdir: /tmp/repo/.git/worktrees/\(name)\n".utf8)
      .write(to: standardizedURL.appending(path: ".git"))
    defer {
      try? fileManager.removeItem(at: standardizedURL)
    }

    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          // Git reports the raw, non-standardized path with the /private prefix.
          return ShellOutput(
            stdout: "worktree /private/tmp/\(name)\nHEAD abc\ndetached\n",
            stderr: "",
            exitCode: 0
          )
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktree = Worktree(
      id: standardizedURL.path(percentEncoded: false),
      name: name,
      detail: "../\(name)",
      workingDirectory: standardizedURL,
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: false)

    // The guard matched, so removal proceeded: the directory was relocated off its original path
    // and git was asked to prune the now-missing worktree.
    let stillExists = fileManager.fileExists(atPath: standardizedURL.path(percentEncoded: false))
    #expect(!stillExists)
    let calls = await store.calls
    #expect(calls.contains { $0.contains("prune") })
  }

  @Test func removeWorktreeFallsBackWhenPruneLeavesLockedRegistration() async throws {
    let fileManager = FileManager.default
    let worktreeURL = fileManager.temporaryDirectory.appending(
      path: "prowl-locked-worktree-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
    try Data("gitdir: /tmp/repo/.git/worktrees/locked\n".utf8)
      .write(to: worktreeURL.appending(path: ".git"))
    defer {
      try? fileManager.removeItem(at: worktreeURL)
    }

    let worktreePath = worktreeURL.path(percentEncoded: false)
    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(worktreePath)\nHEAD abc\nlocked external-lock\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("remove") {
          throw ShellClientError(
            command: "git worktree remove --force \(worktreePath)",
            stdout: "",
            stderr: "fatal: cannot remove a locked working tree, lock reason: external-lock",
            exitCode: 128
          )
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktree = Worktree(
      id: worktreePath,
      name: "locked",
      detail: "../locked",
      workingDirectory: worktreeURL,
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    await #expect(throws: GitClientError.self) {
      _ = try await client.removeWorktree(worktree, deleteBranch: false)
    }

    let calls = await store.calls
    #expect(calls.filter { $0.contains("--porcelain") }.count == 2)
    #expect(calls.contains { $0.contains("prune") })
    #expect(calls.contains { $0.contains("remove") })
    #expect(fileManager.fileExists(atPath: worktreePath))
  }

  @Test func removeWorktreePropagatesDirectRemovalFailure() async {
    let worktreePath = "/tmp/prowl-direct-remove-\(UUID().uuidString)"
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(worktreePath)\nHEAD abc\nlocked external-lock\n",
            stderr: "",
            exitCode: 0
          )
        }
        throw ShellClientError(
          command: "git worktree remove --force \(worktreePath)",
          stdout: "",
          stderr: "fatal: cannot remove a locked working tree",
          exitCode: 128
        )
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktree = Worktree(
      id: worktreePath,
      name: "locked",
      detail: "../locked",
      workingDirectory: URL(fileURLWithPath: worktreePath),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    await #expect(throws: GitClientError.self) {
      _ = try await client.removeWorktree(worktree, deleteBranch: false)
    }
  }

  @Test func removeWorktreeMatchesArbitrarySymlinkedParentPath() async throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appending(
      path: "prowl-symlink-worktree-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let realParentURL = rootURL.appending(path: "real", directoryHint: .isDirectory)
    let symlinkParentURL = rootURL.appending(path: "linked", directoryHint: .isDirectory)
    let realWorktreeURL = realParentURL.appending(path: "feature", directoryHint: .isDirectory)
    let symlinkWorktreeURL = symlinkParentURL.appending(path: "feature", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: realWorktreeURL, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: symlinkParentURL, withDestinationURL: realParentURL)
    try Data("gitdir: /tmp/repo/.git/worktrees/feature\n".utf8)
      .write(to: realWorktreeURL.appending(path: ".git"))
    defer {
      try? fileManager.removeItem(at: rootURL)
    }

    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--porcelain") {
          return ShellOutput(
            stdout: "worktree \(realWorktreeURL.path(percentEncoded: false))\nHEAD abc\ndetached\n",
            stderr: "",
            exitCode: 0
          )
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktree = Worktree(
      id: symlinkWorktreeURL.path(percentEncoded: false),
      name: "feature",
      detail: "../feature",
      workingDirectory: symlinkWorktreeURL,
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: false)

    #expect(!fileManager.fileExists(atPath: realWorktreeURL.path(percentEncoded: false)))
  }

  @Test func forceDeleteLocalBranchUsesForceFlag() async throws {
    let store = ShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "feature\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })

    let outcome = try await client.deleteLocalBranch(
      named: "feature",
      for: URL(fileURLWithPath: "/tmp/repo"),
      force: true
    )

    #expect(outcome == .deleted)
    let calls = await store.calls
    #expect(calls.contains { $0.suffix(3) == ["branch", "-D", "feature"] })
  }

  @Test func safeDeleteLocalBranchPropagatesGitFailure() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("for-each-ref") {
          return ShellOutput(stdout: "feature\n", stderr: "", exitCode: 0)
        }
        throw ShellClientError(command: "git branch -d feature", stdout: "", stderr: "not fully merged", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })

    await #expect(throws: GitClientError.self) {
      _ = try await client.deleteLocalBranch(
        named: "feature",
        for: URL(fileURLWithPath: "/tmp/repo"),
        force: false
      )
    }
  }
}
