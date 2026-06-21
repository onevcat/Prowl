import Foundation
import Sentry

nonisolated let gitLogger = SupaLogger("Git")

nonisolated func shouldFallbackToLoginShell(_ error: Error) -> Bool {
  guard let shellError = error as? ShellClientError else {
    return false
  }
  if shellError.exitCode == 127 {
    return true
  }
  let output = "\(shellError.stderr)\n\(shellError.stdout)".lowercased()
  if output.contains("command not found") {
    return true
  }
  // A Finder-launched app inherits the bare launchd PATH, so `git` is the Xcode
  // shim; when it's unusable (license/active-path) a login shell finds a real git.
  return indicatesUnusableXcodeCommandLineTools(output)
}

nonisolated private func indicatesUnusableXcodeCommandLineTools(_ lowercasedOutput: String) -> Bool {
  let signatures = [
    "xcode license",
    "xcode-select: error",
    "invalid active developer path",
    "no developer tools were found",
    "requires xcode",
  ]
  return signatures.contains { lowercasedOutput.contains($0) }
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
