import Foundation
import Testing

@testable import Prowl

struct GitShellErrorSummaryTests {
  @Test func carriageReturnProgressKeepsOnlyTheFinalState() {
    let progress = (1...99).map { "Updating files:  \($0)% (\($0)/100)" }.joined(separator: "\r")
    let error = ShellClientError(
      command: "wt sw",
      stdout: "",
      stderr: """
        Preparing worktree (new branch 'zesty-badger-331')
        \(progress)\rUpdating files: 100% (100/100), done.
        .git/hooks/post-checkout: line 2: exec: mise: not found
        """,
      exitCode: 127
    )

    let message = gitErrorMessage(for: error)

    #expect(
      message == """
        stderr:
        Preparing worktree (new branch 'zesty-badger-331')
        Updating files: 100% (100/100), done.
        .git/hooks/post-checkout: line 2: exec: mise: not found
        """
    )
  }

  @Test func longOutputKeepsTheLastLines() {
    let lines = (1...50).map { "line \($0)" }
    let error = ShellClientError(
      command: "wt sw",
      stdout: lines.joined(separator: "\n"),
      stderr: "fatal: hook failed\n",
      exitCode: 1
    )

    let message = gitErrorMessage(for: error)

    let expectedStdout = (["…"] + lines.suffix(gitErrorOutputLineLimit)).joined(separator: "\n")
    #expect(message == "stdout:\n\(expectedStdout)\nstderr:\nfatal: hook failed")
  }

  @Test func emptyStreamsAreOmitted() {
    let error = ShellClientError(command: "git status", stdout: " \n", stderr: "", exitCode: 1)

    #expect(gitErrorMessage(for: error).isEmpty)
  }

  @Test func deniedWorkingDirectoryIsReportedAsAccessDenied() {
    let error = ShellClientError(
      command: "wt ls --json",
      stdout: "",
      stderr: deniedWorkingDirectoryStderr,
      exitCode: 1
    )

    let wrapped = wrapShellError(error, operation: .worktreeList, command: "wt ls --json", directory: nil)

    guard case .directoryAccessDenied(let command, let message) = wrapped else {
      Issue.record("Expected directoryAccessDenied, got \(wrapped)")
      return
    }
    #expect(command == "wt ls --json")
    #expect(message == "stderr:\n\(deniedWorkingDirectoryStderr)")
    #expect(wrapped.errorDescription?.hasPrefix("macOS denied access to this folder.") == true)
  }

  @Test func remotePermissionFailureKeepsGitDetails() async throws {
    let lane = RemoteCommandLane(
      run: { command, _ in
        if command.arguments.last?.hasSuffix("command -v git") == true {
          return .exited(.init(exitCode: 0, output: Data("/usr/bin/git".utf8), outputTruncated: false, errorOutput: ""))
        }
        return .exited(
          .init(
            exitCode: 128, output: Data(), outputTruncated: false,
            errorOutput: deniedWorkingDirectoryStderr))
      },
      runScript: { _, _ in throw RemoteRepositoryHostError.unsupported })
    let host = RemoteRepositoryHost(hostProfileID: UUID(), lane: lane)
    do {
      _ = try await host.remoteNames(at: "/srv/app")
      Issue.record("Expected the remote command to fail")
    } catch GitClientError.commandFailed(let command, let message) {
      #expect(command.contains("/srv/app"))
      #expect(message == "stderr:\n\(deniedWorkingDirectoryStderr)")
    }
  }

  @Test func failureKindSeparatesCancellationFromFailure() {
    let killed = ShellClientError(command: "git diff", stdout: "", stderr: "", exitCode: -1)
    let failed = ShellClientError(command: "git diff", stdout: "", stderr: "fatal: bad", exitCode: 128)
    let denied = ShellClientError(command: "git diff", stdout: "", stderr: deniedWorkingDirectoryStderr, exitCode: 128)

    #expect(gitFailureKind(for: CancellationError(), isCancelled: false) == .cancelled)
    #expect(gitFailureKind(for: killed, isCancelled: true) == .cancelled)
    #expect(gitFailureKind(for: killed, isCancelled: false) == .other)
    #expect(gitFailureKind(for: failed, isCancelled: true) == .other)
    #expect(gitFailureKind(for: denied, isCancelled: false) == .directoryAccessDenied)
  }

  @Test func failureLogContainsOnlyPublicFields() {
    let line = gitFailureLogLine(operation: .repoRoot, exitCode: 128, kind: .other)

    #expect(line == "git command failed operation=repo_root exit_code=128 failure_kind=other")
  }

  @Test func workingDirectoryComesFromTheDashCArgument() {
    #expect(gitWorkingDirectory(["-C", "/repo", "status"]) == "/repo")
    #expect(gitWorkingDirectory(["status", "-C", "/repo"]) == nil)
    #expect(gitWorkingDirectory(["-C"]) == nil)
  }

}

private func gitErrorMessage(for error: ShellClientError) -> String {
  guard
    case .commandFailed(_, let message) = wrapShellError(
      error, operation: .worktreeCreate, command: "wt sw", directory: nil)
  else {
    Issue.record("Expected commandFailed")
    return ""
  }
  return message
}

nonisolated private let deniedWorkingDirectoryStderr = """
  shell-init: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
  fatal: Unable to read current working directory: Operation not permitted
  error: not a git repository
  """
