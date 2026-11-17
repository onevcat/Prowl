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

    let wrapped = wrapShellError(error, operation: .worktreeList, command: "wt ls --json", directory: "/repo")

    guard case .directoryAccessDenied(let command, let message) = wrapped else {
      Issue.record("Expected directoryAccessDenied, got \(wrapped)")
      return
    }
    #expect(command == "wt ls --json")
    #expect(message == "stderr:\n\(deniedWorkingDirectoryStderr)")
    #expect(wrapped.errorDescription?.hasPrefix("macOS denied access to this folder.") == true)
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

  @Test func failureLogNamesTheDirectoryAndTheEndOfStderr() {
    let error = ShellClientError(
      command: "git rev-parse --git-dir",
      stdout: "",
      stderr: "line 1\nline 2\nline 3\nfatal: last line\n",
      exitCode: 128
    )

    let line = gitFailureLogLine(
      operation: .repoRoot, error: error, kind: .other, directory: "/Users/me/Documents/repo")

    #expect(
      line == """
        git command failed operation=repo_root exit_code=128 failure_kind=other \
        directory=/Users/me/Documents/repo stderr_tail="line 2 | line 3 | fatal: last line"
        """
    )
  }

  @Test func directoryComesFromTheGitDashCArgument() {
    #expect(gitDirectoryArgument(["-C", "/repo", "status"]) == "/repo")
    #expect(gitDirectoryArgument(["status"]) == nil)
  }
}

private func gitErrorMessage(for error: ShellClientError) -> String {
  guard case .commandFailed(_, let message) = wrapShellError(error, operation: .worktreeCreate, command: "wt sw")
  else {
    Issue.record("Expected commandFailed")
    return ""
  }
  return message
}

private let deniedWorkingDirectoryStderr = """
  shell-init: error retrieving current directory: getcwd: cannot access parent directories: Operation not permitted
  fatal: Unable to read current working directory: Operation not permitted
  error: not a git repository
  """
