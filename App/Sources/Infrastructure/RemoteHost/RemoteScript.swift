import Foundation

/// A bundled script that runs with `bash -s` on the host (docs-ai 084 B1), such as `wt`.
/// The text and its arguments travel on stdin, so the remote login shell parses neither.
nonisolated struct RemoteScript: Equatable, Sendable {
  var text: String
  var arguments: [String]
  var workingDirectory: String?

  init(text: String, arguments: [String] = [], workingDirectory: String? = nil) {
    self.text = text
    self.arguments = arguments
    self.workingDirectory = workingDirectory
  }

  /// The stdin for `bash -s`. The script runs inside a function, which bash parses as a
  /// whole before it runs it, so a command in the script that reads stdin cannot consume
  /// the rest of the script; the function's stdin is `/dev/null`.
  func standardInput(path: String?) throws(RemoteShellCommand.ValidationError) -> String {
    let values = [text] + arguments + [workingDirectory ?? "", path ?? ""]
    guard !values.contains(where: { $0.utf8.contains(0) }) else { throw .nulByte }
    var lines: [String] = []
    if let workingDirectory {
      let failureStatus = RemoteShellCommand.workingDirectoryFailureStatus
      lines.append("cd -- \(RemoteShellCommand.quote(workingDirectory)) || exit \(failureStatus)")
    }
    if let path {
      lines.append("PATH=\(RemoteShellCommand.quote(path))")
      lines.append("export PATH")
    }
    lines.append((["set", "--"] + arguments.map(RemoteShellCommand.quote)).joined(separator: " "))
    lines.append("__prowl_script() {")
    lines.append(text.hasSuffix("\n") ? String(text.dropLast()) : text)
    lines.append("}")
    lines.append(#"__prowl_script "$@" </dev/null"#)
    return lines.joined(separator: "\n") + "\n"
  }
}

/// Splits streamed output into lines. Chunks arrive on the runner's reader thread.
nonisolated final class RemoteOutputLineSplitter: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()
  private let onLine: @Sendable (String) -> Void

  init(onLine: @escaping @Sendable (String) -> Void) {
    self.onLine = onLine
  }

  func append(_ chunk: Data) {
    let lines: [Data] = lock.withLock {
      pending.append(chunk)
      var complete: [Data] = []
      while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
        complete.append(pending[pending.startIndex..<newline])
        pending.removeSubrange(pending.startIndex...newline)
      }
      return complete
    }
    for line in lines { onLine(Self.text(line)) }
  }

  /// Delivers a last line that has no newline.
  func finish() {
    let rest: Data = lock.withLock {
      defer { pending.removeAll() }
      return pending
    }
    if !rest.isEmpty { onLine(Self.text(rest)) }
  }

  /// UTF-8, or Latin-1 for bytes that are not UTF-8 (a path in another encoding), so a line
  /// never turns empty.
  private static func text(_ line: Data) -> String {
    String(bytes: line, encoding: .utf8) ?? String(bytes: line, encoding: .isoLatin1) ?? ""
  }
}
