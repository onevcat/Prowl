import Foundation

/// Reads `key = value` lines from Ghostty config files and their `config-file`
/// includes, in the order Ghostty loads them. Use it for values that
/// `ghostty_config_get` cannot report as written, such as a same-name
/// `theme = light:X,dark:X` pair.
nonisolated enum GhosttyRawConfig {
  struct Entry: Equatable, Sendable {
    let key: String
    let value: String
  }

  /// The entries of `files`, then of their includes. Like Ghostty, includes load
  /// after every file that names them, in the order they are named. Each file is
  /// read once, so include cycles stop; missing files are skipped.
  static func entries(files: [URL]) -> [Entry] {
    var queue = files.map(\.standardizedFileURL)
    var visited = Set<URL>()
    var result: [Entry] = []
    var index = 0
    while index < queue.count {
      let file = queue[index]
      index += 1
      guard visited.insert(file).inserted,
        let contents = try? String(contentsOf: file, encoding: .utf8)
      else { continue }
      for entry in entries(in: contents) {
        result.append(entry)
        if entry.key == "config-file", let include = includeURL(entry.value, relativeTo: file) {
          queue.append(include)
        }
      }
    }
    return result
  }

  /// The value of the last `key` line, or `nil` when there is none or the last one
  /// is blank (a blank value clears the setting in Ghostty).
  static func lastValue(of key: String, files: [URL]) -> String? {
    guard let entry = entries(files: files).last(where: { $0.key == key }), !entry.value.isEmpty else {
      return nil
    }
    return entry.value
  }

  /// The entries of one file. Like Ghostty, a comment takes a full line, and quotes
  /// around a whole value are removed.
  static func entries(in contents: String) -> [Entry] {
    contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { return nil }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      return Entry(key: key, value: unquoted(value))
    }
  }

  /// Resolves a `config-file` value like Ghostty: a leading `?` marks it optional,
  /// `~/` starts at the home folder, and a relative path starts at the folder of
  /// the file that names it.
  static func includeURL(_ value: String, relativeTo file: URL) -> URL? {
    var path = value
    if path.hasPrefix("?") {
      path.removeFirst()
    }
    path = unquoted(path)
    guard !path.isEmpty else { return nil }
    if path.hasPrefix("~/") {
      return FileManager.default.homeDirectoryForCurrentUser
        .appending(path: String(path.dropFirst(2)))
        .standardizedFileURL
    }
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    return file.deletingLastPathComponent().appending(path: path).standardizedFileURL
  }

  private static func unquoted(_ value: String) -> String {
    guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    return String(value.dropFirst().dropLast())
  }
}
