import Foundation
import Sentry

nonisolated let gitLogger = ProwlLogger("Git")

/// Only direct Git discovery can establish that a folder is not a repository.
/// Existing or inaccessible metadata makes the result uncertain, even if Git says otherwise.
nonisolated func isConfirmedNonRepository(_ error: Error, at directory: URL) -> Bool {
  guard let error = error as? ShellClientError, error.exitCode == 128 else { return false }
  let message = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
  let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
  let stoppedAtBoundary =
    lines.count == 2
    && lines[0].hasPrefix("fatal: not a git repository (or any parent up to mount point /")
    && lines[0].hasSuffix(")")
    && lines[1] == "Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set)."
  guard
    message == "fatal: not a git repository (or any of the parent directories): .git"
      || stoppedAtBoundary
  else {
    return false
  }
  var current = directory.resolvingSymlinksInPath().standardizedFileURL
  while true {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else {
      return false
    }
    if names.contains(".git") || (names.contains("HEAD") && names.contains("objects")) {
      return false
    }
    let parent = current.deletingLastPathComponent().standardizedFileURL
    if parent.path == current.path { return true }
    current = parent
  }
}

/// The most output lines per stream that a Git error message keeps.
nonisolated let gitErrorOutputLineLimit = 20

/// Keeps the end of a command's output, where Git and hooks report the failure.
/// Progress output rewrites one line with carriage returns, so only the text after
/// the last carriage return of each line stays.
nonisolated func gitErrorOutputSummary(_ output: String) -> String {
  let lines =
    output
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { line in
      line.split(separator: "\r").last { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
    }
    .filter { !$0.allSatisfy(\.isWhitespace) }
  guard lines.count > gitErrorOutputLineLimit else { return lines.joined(separator: "\n") }
  return (["…"] + lines.suffix(gitErrorOutputLineLimit)).joined(separator: "\n")
}

/// Why a Git command did not succeed. Logs and Sentry use it to keep cancelled
/// commands out of the failure counts.
nonisolated enum GitFailureKind: String, Equatable, Sendable {
  /// The task that ran the command was cancelled, for example by a newer reload.
  case cancelled
  /// The host denied access to the working directory (EPERM).
  case directoryAccessDenied = "directory_access_denied"
  case other
}

nonisolated func gitFailureKind(for error: Error, isCancelled: Bool) -> GitFailureKind {
  if error is CancellationError { return .cancelled }
  guard let shellError = error as? ShellClientError else { return isCancelled ? .cancelled : .other }
  if isDeniedWorkingDirectory(shellError.stderr) { return .directoryAccessDenied }
  // A cancelled command ends without an exit status, which the shell client reports as -1.
  if isCancelled && shellError.exitCode == -1 { return .cancelled }
  return .other
}

/// Shells and Git report EPERM when they cannot read the working directory.
nonisolated private func isDeniedWorkingDirectory(_ stderr: String) -> Bool {
  stderr.split(separator: "\n").contains { line in
    line.contains("Operation not permitted")
      && (line.contains("Unable to read current working directory") || line.contains("getcwd:"))
  }
}

/// Only these fields can appear in the public Git failure log.
nonisolated func gitFailureLogLine(operation: GitOperation, exitCode: Int32, kind: GitFailureKind) -> String {
  "git command failed operation=\(operation.rawValue) exit_code=\(exitCode) failure_kind=\(kind.rawValue)"
}

/// The directory that a `git -C <path> …` command runs in.
nonisolated func gitWorkingDirectory(_ arguments: [String]) -> String? {
  guard arguments.count > 1, arguments[0] == "-C" else { return nil }
  return arguments[1]
}

/// Converts a failed command into a `GitClientError` and records the failure.
/// `directory` is where the command ran. The log shows only a hash of it.
nonisolated func wrapShellError(
  _ error: Error,
  operation: GitOperation,
  command: String,
  directory: String?
) -> GitClientError {
  let kind = gitFailureKind(for: error, isCancelled: Task.isCancelled)
  let gitError: GitClientError
  if let shellError = error as? ShellClientError {
    var messageParts: [String] = []
    let stdout = gitErrorOutputSummary(shellError.stdout)
    if !stdout.isEmpty {
      messageParts.append("stdout:\n\(stdout)")
    }
    let stderr = gitErrorOutputSummary(shellError.stderr)
    if !stderr.isEmpty {
      messageParts.append("stderr:\n\(stderr)")
    }
    let message = messageParts.joined(separator: "\n")
    gitError =
      kind == .directoryAccessDenied && !shellError.isRemote
      ? .directoryAccessDenied(command: command, message: message)
      : .commandFailed(command: command, message: message)
  } else {
    gitError = .commandFailed(command: command, message: error.localizedDescription)
  }
  if kind == .cancelled {
    gitLogger.debug("git command cancelled operation=\(operation.rawValue)")
    return gitError
  }
  let exitCode = (error as? ShellClientError)?.exitCode ?? -1
  let line = gitFailureLogLine(operation: operation, exitCode: exitCode, kind: kind)
  if let directory {
    gitLogger.warning(line, hashedField: "directory", value: directory)
  } else {
    gitLogger.warning(line)
  }
  #if !DEBUG
    SentrySDK.logger.error(
      "git command failed",
      attributes: [
        "operation": operation.rawValue,
        "exit_code": Int(exitCode),
        "failure_kind": kind.rawValue,
      ]
    )
  #endif
  return gitError
}
