import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

nonisolated final class GitWorktreeDiscoveryRecorder: @unchecked Sendable {
  struct Invocation: Equatable {
    let executablePath: String
    let arguments: [String]
    let currentDirectoryPath: String?
  }

  private let lock = NSLock()
  private var runInvocationsValue: [Invocation] = []
  private var loginInvocationsValue: [Invocation] = []

  func recordRun(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
    lock.lock()
    runInvocationsValue.append(
      Invocation(
        executablePath: executableURL.path(percentEncoded: false),
        arguments: arguments,
        currentDirectoryPath: currentDirectoryURL?.path(percentEncoded: false)
      )
    )
    lock.unlock()
  }

  func recordLogin(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
    lock.lock()
    loginInvocationsValue.append(
      Invocation(
        executablePath: executableURL.path(percentEncoded: false),
        arguments: arguments,
        currentDirectoryPath: currentDirectoryURL?.path(percentEncoded: false)
      )
    )
    lock.unlock()
  }

  func runInvocations() -> [Invocation] {
    lock.lock()
    let value = runInvocationsValue
    lock.unlock()
    return value
  }

  func loginInvocations() -> [Invocation] {
    lock.lock()
    let value = loginInvocationsValue
    lock.unlock()
    return value
  }
}

struct GitClientWorktreeDiscoveryTests {
  @Test func repoRootUsesDirectBundledWtExecution() async throws {
    let recorder = GitWorktreeDiscoveryRecorder()
    let shell = ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        recorder.recordRun(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return ShellOutput(stdout: "/tmp/repo\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.recordLogin(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        Issue.record("repoRoot should not use runLogin when direct execution succeeds")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let worktreeURL = URL(fileURLWithPath: "/tmp/repo/worktree")

    let root = try await client.repoRoot(for: worktreeURL)

    #expect(root.standardizedFileURL.path(percentEncoded: false).hasSuffix("/tmp/repo"))
    let runs = recorder.runInvocations()
    #expect(runs.count == 2)
    #expect(runs.first?.arguments.suffix(2) == ["rev-parse", "--git-dir"])
    if let invocation = runs.last {
      #expect(invocation.arguments.last == "root")
      #expect(invocation.arguments.contains("PATH=/usr/bin:/bin"))
      let normalizedPath = URL(fileURLWithPath: invocation.currentDirectoryPath ?? "")
        .standardizedFileURL
        .path(percentEncoded: false)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      #expect(normalizedPath == "tmp/repo")
    } else {
      Issue.record("Expected one direct bundled wt invocation for repoRoot")
    }
    #expect(recorder.loginInvocations().isEmpty)
  }

  @Test func worktreesUseDirectBundledWtExecution() async throws {
    let recorder = GitWorktreeDiscoveryRecorder()
    let output = """
      [
        {"branch":"main","path":"/tmp/repo","head":"abc","is_bare":false},
        {"branch":"feature","path":"/tmp/repo/.worktrees/feature","head":"def","is_bare":false}
      ]
      """
    let shell = ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        recorder.recordRun(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.recordLogin(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        Issue.record("worktrees should not use runLogin when direct execution succeeds")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let worktrees = try await client.worktrees(for: repoRoot)

    #expect(worktrees.map(\.id) == ["/tmp/repo", "/tmp/repo/.worktrees/feature"])
    let runs = recorder.runInvocations()
    #expect(runs.count == 1)
    if let invocation = runs.first {
      #expect(invocation.arguments.suffix(2) == ["ls", "--json"])
      #expect(invocation.arguments.contains("PATH=/usr/bin:/bin"))
      #expect(invocation.currentDirectoryPath == "/tmp/repo")
    } else {
      Issue.record("Expected one direct bundled wt invocation for worktree discovery")
    }
    #expect(recorder.loginInvocations().isEmpty)
  }

  @Test func worktreesDeduplicateStandardizedPaths() async throws {
    let output = """
      [
        {"branch":"main","path":"/tmp/repo","head":"abc","is_bare":false},
        {"branch":"feature","path":"/tmp/repo/.worktrees/feature","head":"def","is_bare":false},
        {"branch":"feature","path":"/tmp/repo/.worktrees/./feature","head":"def","is_bare":false}
      ]
      """
    let shell = ShellClient(
      run: { _, _, _ in
        ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("worktrees should not use runLogin when direct execution succeeds")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let worktrees = try await client.worktrees(for: repoRoot)

    #expect(worktrees.map(\.id) == ["/tmp/repo", "/tmp/repo/.worktrees/feature"])
  }

  @Test func repoRootDoesNotReplayDiscoveryAgainstAnotherEnvironment() async {
    let calls = LockIsolated(0)
    let shell = ShellClient(
      run: { _, _, _ in
        calls.withValue { $0 += 1 }
        throw ShellClientError(command: "git", stdout: "", stderr: "permission denied", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("Git selection must precede the operation, not replay it")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    await #expect(throws: GitClientError.self) {
      try await client.repoRoot(for: URL(fileURLWithPath: "/tmp/repo"))
    }
    #expect(calls.value == 1)
  }

  @Test func worktreesDoNotFallbackToLoginShellForNonGitDirectory() async {
    let recorder = GitWorktreeDiscoveryRecorder()
    let shell = ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        recorder.recordRun(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        throw ShellClientError(
          command: "wt ls --json",
          stdout: "",
          stderr: "fatal: not a git repository (or any of the parent directories): .git",
          exitCode: 128
        )
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.recordLogin(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        Issue.record("worktrees should not fallback to runLogin for non-git directories")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })

    await #expect(throws: GitClientError.self) {
      _ = try await client.worktrees(for: URL(fileURLWithPath: "/tmp/not-a-repo"))
    }

    #expect(recorder.runInvocations().count == 1)
    #expect(recorder.loginInvocations().isEmpty)
  }

  @Test func worktreeListDoesNotReplayAfterAnOperationFailure() async {
    let calls = LockIsolated(0)
    let shell = ShellClient(
      run: { _, _, _ in
        calls.withValue { $0 += 1 }
        throw ShellClientError(command: "wt ls", stdout: "", stderr: "permission denied", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("Worktree listing must use the selected Git environment")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })
    await #expect(throws: GitClientError.self) {
      try await client.worktrees(for: URL(fileURLWithPath: "/tmp/repo"))
    }
    #expect(calls.value == 1)
  }
}
