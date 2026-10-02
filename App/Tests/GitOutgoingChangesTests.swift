import Foundation
import Testing

@testable import supacode

actor OutgoingChangesShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitOutgoingChangesTests {
  @Test func pullRequestBaseResolvesFullyQualifiedTargetRemoteRefIncludingEnterpriseHostAndSSHPort() async throws {
    let store = OutgoingChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("get-url") {
          switch arguments.last {
          case "origin":
            return ShellOutput(stdout: "git@ghe.example:fork/project.git\n", stderr: "", exitCode: 0)
          case "upstream":
            return ShellOutput(
              stdout: "ssh://git@ghe.example:2222/target/project.git\n",
              stderr: "",
              exitCode: 0
            )
          default:
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
          }
        }
        if arguments.contains("remote") {
          return ShellOutput(stdout: "origin\nupstream\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("rev-parse") {
          return ShellOutput(stdout: "0123456789abcdef\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let resolution = try await client.outgoingBaseResolution(
      pullRequest: GitPullRequestBase(
        url: "https://ghe.example/target/project/pull/42",
        baseRefName: "main"
      ),
      configuredBaseRef: nil,
      in: URL(fileURLWithPath: "/tmp/repo")
    )

    #expect(resolution.ref == "refs/remotes/upstream/main")
    #expect(resolution.displayName == "upstream/main")
    #expect(resolution.source == .pullRequest)
    let calls = await store.calls
    #expect(calls.contains { $0.contains("refs/remotes/upstream/main") })
    // The short name must never reach rev-parse/merge-base, or a local branch
    // literally named `upstream/main` would win Git's disambiguation.
    #expect(
      !calls.contains { arguments in
        arguments.contains("rev-parse") && arguments.contains("upstream/main")
      }
    )
  }

  @Test func pullRequestBaseErrorsWhenNoRemoteMatchesInsteadOfFallingBackToOrigin() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("get-url") {
          return ShellOutput(stdout: "git@github.com:fork/project.git\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("remote") {
          return ShellOutput(stdout: "origin\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    await #expect(
      throws: OutgoingBaseResolutionError.noMatchingRemote(host: "github.com", repositoryPath: "upstream/project")
    ) {
      try await client.outgoingBaseResolution(
        pullRequest: GitPullRequestBase(
          url: "https://github.com/upstream/project/pull/42",
          baseRefName: "main"
        ),
        configuredBaseRef: nil,
        in: URL(fileURLWithPath: "/tmp/repo")
      )
    }
  }

  @Test func pullRequestBaseErrorsWhenMultipleRemotesMatchAndNamesThem() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("get-url") {
          return ShellOutput(stdout: "git@github.com:upstream/project.git\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("remote") {
          return ShellOutput(stdout: "origin\nmirror\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    await #expect(throws: OutgoingBaseResolutionError.multipleMatchingRemotes(["mirror", "origin"])) {
      try await client.outgoingBaseResolution(
        pullRequest: GitPullRequestBase(
          url: "https://github.com/upstream/project/pull/42",
          baseRefName: "main"
        ),
        configuredBaseRef: nil,
        in: URL(fileURLWithPath: "/tmp/repo")
      )
    }
  }

  @Test func pullRequestBaseErrorsWhenBaseRefIsNotFetchedInsteadOfCascading() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("get-url") {
          return ShellOutput(stdout: "git@github.com:upstream/project.git\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("remote") {
          return ShellOutput(stdout: "origin\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("rev-parse") {
          throw ShellClientError(command: "git rev-parse", stdout: "", stderr: "fatal: bad revision", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    await #expect(throws: OutgoingBaseResolutionError.unresolvedPullRequestBase(remote: "origin", branch: "feature-a"))
    {
      try await client.outgoingBaseResolution(
        pullRequest: GitPullRequestBase(
          url: "https://github.com/upstream/project/pull/42",
          baseRefName: "feature-a"
        ),
        // A configured base must not rescue a present-but-unfetched PR base.
        configuredBaseRef: "origin/main",
        in: URL(fileURLWithPath: "/tmp/repo")
      )
    }
  }

  @Test func configuredBaseResolvesInRemoteNamespaceWhenNoPullRequestExists() async throws {
    let store = OutgoingChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("rev-parse") {
          if arguments.contains("refs/remotes/origin/develop") {
            return ShellOutput(stdout: "0123456789abcdef\n", stderr: "", exitCode: 0)
          }
          throw ShellClientError(command: "git rev-parse", stdout: "", stderr: "fatal: bad revision", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let resolution = try await client.outgoingBaseResolution(
      pullRequest: nil,
      configuredBaseRef: "origin/develop",
      in: URL(fileURLWithPath: "/tmp/repo")
    )

    #expect(resolution.ref == "refs/remotes/origin/develop")
    #expect(resolution.displayName == "origin/develop")
    #expect(resolution.source == .repositorySetting)
  }

  @Test func configuredBaseErrorsWhenUnresolvableInsteadOfCascadingToAutomatic() async {
    let store = OutgoingChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("rev-parse") {
          throw ShellClientError(command: "git rev-parse", stdout: "", stderr: "fatal: bad revision", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    await #expect(throws: OutgoingBaseResolutionError.unresolvedRepositorySettingBase("origin/develop")) {
      try await client.outgoingBaseResolution(
        pullRequest: nil,
        configuredBaseRef: "origin/develop",
        in: URL(fileURLWithPath: "/tmp/repo")
      )
    }
    let calls = await store.calls
    #expect(!calls.contains { $0.contains("symbolic-ref") })
  }

  @Test func automaticBaseIsUsedWhenNoPullRequestOrSettingExists() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("symbolic-ref") {
          return ShellOutput(stdout: "refs/remotes/origin/main\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("rev-parse") {
          return ShellOutput(stdout: "0123456789abcdef\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let resolution = try await client.outgoingBaseResolution(
      pullRequest: nil,
      configuredBaseRef: "  ",
      in: URL(fileURLWithPath: "/tmp/repo")
    )

    #expect(resolution.ref == "refs/remotes/origin/main")
    #expect(resolution.displayName == "origin/main")
    #expect(resolution.source == .automatic)
  }

  @Test func outgoingDiffNameStatusUsesCapturedRevisionsAndPreservesUnicodePaths() async throws {
    let store = OutgoingChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "M\t中文.swift\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let comparison = GitOutgoingChangesComparison(
      base: OutgoingBaseResolution(
        ref: "refs/remotes/upstream/main",
        displayName: "upstream/main",
        source: .pullRequest
      ),
      mergeBase: "merge-base-oid",
      head: "head-oid"
    )

    let output = try await client.outgoingDiffNameStatus(
      for: comparison,
      at: URL(fileURLWithPath: "/tmp/repo")
    )

    #expect(output.contains("中文.swift"))
    let calls = await store.calls
    #expect(calls.count == 1)
    let arguments = calls[0]
    #expect(arguments.contains("core.quotePath=false"))
    #expect(arguments.contains("merge-base-oid"))
    #expect(arguments.contains("head-oid"))
  }

  @Test func outgoingComparisonUsesMergeBaseAndHeadAndExcludesWorkingTreeChanges() async throws {
    let repositoryURL = FileManager.default.temporaryDirectory.appending(
      path: "prowl-outgoing-changes-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: repositoryURL) }

    try runOutgoingChangesGit(["init", repositoryURL.path(percentEncoded: false)])
    try runOutgoingChangesGit([
      "-C", repositoryURL.path(percentEncoded: false), "config", "user.email", "test@example.com",
    ])
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "config", "user.name", "Test User"])

    let trackedURL = repositoryURL.appending(path: "tracked.txt")
    try "base\n".write(to: trackedURL, atomically: true, encoding: .utf8)
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "add", "tracked.txt"])
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "commit", "-m", "base"])
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "branch", "-M", "main"])

    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "checkout", "-b", "feature"])
    try "feature\n".write(to: trackedURL, atomically: true, encoding: .utf8)
    try "feature only\n".write(
      to: repositoryURL.appending(path: "feature-only.txt"),
      atomically: true,
      encoding: .utf8
    )
    try runOutgoingChangesGit([
      "-C", repositoryURL.path(percentEncoded: false), "add", "tracked.txt", "feature-only.txt",
    ])
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "commit", "-m", "feature"])

    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "checkout", "main"])
    try "main advanced\n".write(to: trackedURL, atomically: true, encoding: .utf8)
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "add", "tracked.txt"])
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "commit", "-m", "main advanced"])
    try runOutgoingChangesGit(["-C", repositoryURL.path(percentEncoded: false), "checkout", "feature"])

    try "uncommitted\n".write(to: trackedURL, atomically: true, encoding: .utf8)
    try "untracked\n".write(
      to: repositoryURL.appending(path: "untracked.txt"),
      atomically: true,
      encoding: .utf8
    )

    let client = GitClient()
    let resolution = try await client.outgoingBaseResolution(
      pullRequest: nil,
      configuredBaseRef: "main",
      in: repositoryURL
    )
    let comparison = try await client.outgoingChangesComparison(base: resolution, at: repositoryURL)
    let files = DiffChangedFile.parseNameStatus(
      try await client.outgoingDiffNameStatus(for: comparison, at: repositoryURL)
    )
    let oldContents = await client.showFile("tracked.txt", at: comparison.mergeBase, in: repositoryURL)
    let newContents = await client.showFile("tracked.txt", at: comparison.head, in: repositoryURL)

    #expect(resolution.ref == "refs/heads/main")
    #expect(resolution.displayName == "main")
    #expect(resolution.source == .repositorySetting)
    #expect(files.map(\.displayPath).sorted() == ["feature-only.txt", "tracked.txt"])
    #expect(!files.contains { $0.displayPath == "untracked.txt" })
    #expect(oldContents == "base")
    #expect(newContents == "feature")
  }

  @Test func pullRequestBaseIgnoresLocalBranchShadowingTheRemoteTrackingRef() async throws {
    let repositoryURL = FileManager.default.temporaryDirectory.appending(
      path: "prowl-outgoing-shadow-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: repositoryURL) }
    let path = repositoryURL.path(percentEncoded: false)

    try runOutgoingChangesGit(["init", path])
    try runOutgoingChangesGit(["-C", path, "config", "user.email", "test@example.com"])
    try runOutgoingChangesGit(["-C", path, "config", "user.name", "Test User"])

    try "base\n".write(to: repositoryURL.appending(path: "file.txt"), atomically: true, encoding: .utf8)
    try runOutgoingChangesGit(["-C", path, "add", "file.txt"])
    try runOutgoingChangesGit(["-C", path, "commit", "-m", "base"])
    try runOutgoingChangesGit(["-C", path, "branch", "-M", "main"])
    let baseCommit = try runOutgoingChangesGit(["-C", path, "rev-parse", "HEAD"])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    try runOutgoingChangesGit(["-C", path, "checkout", "-b", "feature"])
    try "feature\n".write(to: repositoryURL.appending(path: "file.txt"), atomically: true, encoding: .utf8)
    try runOutgoingChangesGit(["-C", path, "add", "file.txt"])
    try runOutgoingChangesGit(["-C", path, "commit", "-m", "feature"])
    let featureCommit = try runOutgoingChangesGit(["-C", path, "rev-parse", "HEAD"])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    try runOutgoingChangesGit(["-C", path, "remote", "add", "upstream", "https://github.com/target/project.git"])
    // The remote-tracking base sits at the base commit...
    try runOutgoingChangesGit(["-C", path, "update-ref", "refs/remotes/upstream/main", baseCommit])
    // ...while a local branch literally named `upstream/main` sits at the
    // feature tip. Short-name disambiguation would pick the local branch and
    // report an empty outgoing diff.
    try runOutgoingChangesGit(["-C", path, "branch", "upstream/main", featureCommit])

    let client = GitClient()
    let resolution = try await client.outgoingBaseResolution(
      pullRequest: GitPullRequestBase(
        url: "https://github.com/target/project/pull/1",
        baseRefName: "main"
      ),
      configuredBaseRef: nil,
      in: repositoryURL
    )
    let comparison = try await client.outgoingChangesComparison(base: resolution, at: repositoryURL)
    let files = DiffChangedFile.parseNameStatus(
      try await client.outgoingDiffNameStatus(for: comparison, at: repositoryURL)
    )

    #expect(resolution.ref == "refs/remotes/upstream/main")
    #expect(comparison.mergeBase == baseCommit)
    #expect(files.map(\.displayPath) == ["file.txt"])
  }
}

private struct OutgoingChangesGitCommandError: Error {
  let output: String
}

@discardableResult
private func runOutgoingChangesGit(_ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  process.environment = environment
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  process.waitUntilExit()
  let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  guard process.terminationStatus == 0 else {
    throw OutgoingChangesGitCommandError(output: output)
  }
  return output
}
