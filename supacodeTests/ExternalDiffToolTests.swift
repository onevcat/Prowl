import Dependencies
import Foundation
import Testing

@testable import supacode

@MainActor
struct ExternalDiffToolTests {
  @Test func defaultSettingsUseBuiltInDiffTool() {
    #expect(GlobalSettings.default.externalDiffToolID == ExternalDiffTool.builtIn.settingsID)
    #expect(GlobalSettings.default.externalDiffCustomCommand == "")
  }

  @Test func launchModesMatchSupportedTools() {
    #expect(ExternalDiffTool.builtIn.launchMode == .builtIn)
    #expect(ExternalDiffTool.hunk.launchMode == .terminal)
    #expect(ExternalDiffTool.fileMerge.launchMode == .gui)
    #expect(ExternalDiffTool.kaleidoscope.launchMode == .gui)
    #expect(ExternalDiffTool.custom.launchMode == .gui)
  }

  @Test func settingsMenuListsAllSupportedTools() {
    #expect(
      ExternalDiffTool.settingsMenuCases == [
        .builtIn,
        .hunk,
        .fileMerge,
        .kaleidoscope,
        .custom,
      ]
    )
  }

  @Test func explicitSettingsResolveWithoutCheckingInstallation() {
    #expect(ExternalDiffSettings(toolID: ExternalDiffTool.hunk.settingsID, customCommand: "").tool == .hunk)
  }

  @Test func commandTemplateReplacesPlaceholdersWithShellQuotedValues() {
    let context = ExternalDiffCommandContext(
      worktreePath: "/tmp/My Repo/work tree",
      repoPath: "/tmp/My Repo",
      branch: "feature/quote's",
      leftPath: "/tmp/left snapshot",
      rightPath: "/tmp/right snapshot"
    )

    let rendered = ExternalDiffCommandTemplate.render(
      "tool {leftPath} {rightPath} --repo {repoPath} --branch {branch} --worktree {worktreePath}",
      context: context
    )

    let expected =
      "tool '/tmp/left snapshot' '/tmp/right snapshot' --repo '/tmp/My Repo' "
      + "--branch 'feature/quote'\"'\"'s' --worktree '/tmp/My Repo/work tree'"
    #expect(rendered == expected)
  }

  @Test func hunkLaunchesInTerminalTab() async {
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let worktree = Worktree(
      id: "/tmp/repo",
      name: "feature",
      detail: "feature",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    await withDependencies {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    } operation: {
      await ExternalDiffToolClient.liveValue.open(
        ExternalDiffSettings(toolID: ExternalDiffTool.hunk.settingsID, customCommand: ""),
        worktree,
        .appDefaults
      ) { _ in }
    }

    #expect(
      sentCommands.value == [
        .createTabWithInput(
          worktree,
          input: "hunk diff",
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: "Hunk Diff",
          customCommandIcon: "square.split.2x1"
        )
      ]
    )
  }

  @Test func customCommandRunsRenderedShellCommandInWorktree() async throws {
    let runs = LockIsolated<[ShellRun]>([])
    let worktree = Worktree(
      id: "/tmp/repo",
      name: "feature",
      detail: "feature",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/root")
    )
    let snapshot = ExternalDiffSnapshotPair(
      leftURL: URL(fileURLWithPath: "/tmp/left"),
      rightURL: URL(fileURLWithPath: "/tmp/right")
    )

    await withDependencies {
      $0.externalDiffSnapshotClient.makeSnapshotPair = { _ in snapshot }
      $0.shellClient.runLoginImpl = { executable, arguments, cwd, _ in
        runs.withValue {
          $0.append(ShellRun(executable: executable, arguments: arguments, currentDirectoryURL: cwd))
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    } operation: {
      await ExternalDiffToolClient.liveValue.open(
        ExternalDiffSettings(
          toolID: ExternalDiffTool.custom.settingsID,
          customCommand: "my-diff {leftPath} {rightPath} --repo {repoPath}"
        ),
        worktree,
        .appDefaults
      ) { _ in }
    }

    let run = try #require(runs.value.first)
    #expect(run.executable.path(percentEncoded: false) == "/bin/zsh")
    #expect(run.arguments == ["-lc", "my-diff '/tmp/left' '/tmp/right' --repo '/tmp/root'"])
    #expect(run.currentDirectoryURL == worktree.workingDirectory)
  }

  @Test func snapshotPairIncludesModifiedAndUntrackedFiles() async throws {
    let repoURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-external-diff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repoURL) }
    try runGit(["init"], in: repoURL)
    try runGit(["config", "user.email", "test@example.com"], in: repoURL)
    try runGit(["config", "user.name", "Test User"], in: repoURL)
    try "one\n".write(to: repoURL.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
    try runGit(["add", "tracked.txt"], in: repoURL)
    try runGit(["commit", "--no-verify", "-m", "Initial"], in: repoURL)
    try "two\n".write(to: repoURL.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
    try "new\n".write(to: repoURL.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)

    let worktree = Worktree(
      id: repoURL.path(percentEncoded: false),
      name: "main",
      detail: "main",
      workingDirectory: repoURL,
      repositoryRootURL: repoURL
    )

    let snapshot = try await ExternalDiffSnapshotClient.liveValue.makeSnapshotPair(worktree)

    #expect(try String(contentsOf: snapshot.leftURL.appending(path: "tracked.txt"), encoding: .utf8) == "one\n")
    #expect(try String(contentsOf: snapshot.rightURL.appending(path: "tracked.txt"), encoding: .utf8) == "two\n")
    #expect(!FileManager.default.fileExists(atPath: snapshot.leftURL.appending(path: "untracked.txt").path()))
    #expect(try String(contentsOf: snapshot.rightURL.appending(path: "untracked.txt"), encoding: .utf8) == "new\n")
  }
}

private struct ShellRun: Equatable {
  let executable: URL
  let arguments: [String]
  let currentDirectoryURL: URL?
}

private func runGit(_ arguments: [String], in directory: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  process.currentDirectoryURL = directory
  var environment = ProcessInfo.processInfo.environment
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_CONFIG_NOSYSTEM"] = "1"
  process.environment = environment
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  process.waitUntilExit()
  let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  guard process.terminationStatus == 0 else {
    let command = arguments.joined(separator: " ")
    let path = directory.path(percentEncoded: false)
    let message = "git \(command) failed in \(path)\nstdout: \(stdoutText)\nstderr: \(stderrText)"
    throw NSError(
      domain: "ExternalDiffToolTests.runGit",
      code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
