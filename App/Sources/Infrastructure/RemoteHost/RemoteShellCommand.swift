import Foundation

/// Remote work as data (docs-ai 082, C5): an executable, its arguments, a working
/// directory, and environment additions. `script` is the only place it becomes shell text;
/// the text is piped to `sh -s`, so the remote login shell never parses it.
nonisolated struct RemoteShellCommand: Equatable, Sendable {
  enum ValidationError: Error, Equatable {
    case emptyExecutable
    case invalidEnvironmentName(String)
    case nulByte
  }

  var executable: String
  var arguments: [String]
  var workingDirectory: String?
  /// Exported before `exec`, in order.
  var environment: [(name: String, value: String)]

  init(
    executable: String, arguments: [String] = [], workingDirectory: String? = nil,
    environment: [(name: String, value: String)] = []
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.executable == rhs.executable && lhs.arguments == rhs.arguments
      && lhs.workingDirectory == rhs.workingDirectory
      && lhs.environment.map(\.name) == rhs.environment.map(\.name)
      && lhs.environment.map(\.value) == rhs.environment.map(\.value)
  }

  /// Exit status of the script when the working directory does not exist.
  static let workingDirectoryFailureStatus: Int32 = 97

  /// POSIX `sh` text that runs the command. A NUL byte cannot be passed through argv or
  /// the environment, so it is rejected instead of truncated.
  func script() throws(ValidationError) -> String {
    guard !executable.isEmpty else { throw .emptyExecutable }
    let values = [executable] + arguments + [workingDirectory ?? ""] + environment.flatMap { [$0.name, $0.value] }
    guard !values.contains(where: { $0.utf8.contains(0) }) else { throw .nulByte }
    var lines: [String] = []
    if let workingDirectory {
      lines.append("cd -- \(Self.quote(workingDirectory)) || exit \(Self.workingDirectoryFailureStatus)")
    }
    for variable in environment {
      guard Self.isValidName(variable.name) else { throw .invalidEnvironmentName(variable.name) }
      lines.append("\(variable.name)=\(Self.quote(variable.value))")
      lines.append("export \(variable.name)")
    }
    lines.append((["exec", Self.quote(executable)] + arguments.map(Self.quote)).joined(separator: " "))
    return lines.joined(separator: "\n") + "\n"
  }

  /// Single-quotes `value` for POSIX `sh`; an embedded quote becomes `'\''`.
  static func quote(_ value: String) -> String {
    "'" + value.replacing("'", with: #"'\''"#) + "'"
  }

  static func isValidName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic)
    else { return false }
    return name.unicodeScalars.allSatisfy {
      $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)))
    }
  }
}
