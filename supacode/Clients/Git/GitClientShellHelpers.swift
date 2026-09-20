import Foundation
import Sentry

nonisolated let gitLogger = SupaLogger("Git")

/// Only direct Git discovery can establish that a folder is not a repository.
/// Existing or inaccessible metadata makes the result uncertain, even if Git says otherwise.
nonisolated func isConfirmedNonRepository(_ error: Error, at directory: URL) -> Bool {
  guard let error = error as? ShellClientError, error.exitCode == 128,
    error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      == "fatal: not a git repository (or any of the parent directories): .git"
  else { return false }
  var current = directory.resolvingSymlinksInPath().standardizedFileURL
  while true {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { return false }
    if names.contains(".git") || (names.contains("HEAD") && names.contains("objects")) { return false }
    let parent = current.deletingLastPathComponent().standardizedFileURL
    if parent.path == current.path { return true }
    current = parent
  }
}

nonisolated func wrapShellError(
  _ error: Error,
  operation: GitOperation,
  command: String
) -> GitClientError {
  let gitError: GitClientError
  var exitCode: Int32 = -1
  if let shellError = error as? ShellClientError {
    exitCode = shellError.exitCode
    var messageParts: [String] = []
    if !shellError.stdout.isEmpty {
      messageParts.append("stdout:\n\(shellError.stdout)")
    }
    if !shellError.stderr.isEmpty {
      messageParts.append("stderr:\n\(shellError.stderr)")
    }
    let message = messageParts.joined(separator: "\n")
    gitError = .commandFailed(command: command, message: message)
  } else {
    gitError = .commandFailed(command: command, message: error.localizedDescription)
  }
  gitLogger.warning("git command failed operation=\(operation.rawValue) exit_code=\(exitCode)")
  #if !DEBUG
    SentrySDK.logger.error(
      "git command failed",
      attributes: [
        "operation": operation.rawValue,
        "exit_code": Int(exitCode),
      ]
    )
  #endif
  return gitError
}
