import Foundation
import ProwlCLIShared

nonisolated struct ShellClientError: LocalizedError, Equatable, Sendable {
  let command: String
  let stdout: String
  let stderr: String
  let exitCode: Int32

  var errorDescription: String? {
    var parts: [String] = ["Command failed: \(command)"]
    if !stdout.isEmpty {
      parts.append("stdout:\n\(stdout)")
    }
    if !stderr.isEmpty {
      parts.append("stderr:\n\(stderr)")
    }
    return parts.joined(separator: "\n")
  }
}
