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

  /// The entries of `files`, then of their includes, as Ghostty loads them
  /// (`Config.loadRecursiveFiles`): every root file first, then the include list in
  /// order while it grows. A blank `config-file` clears the list. Only includes
  /// count as loaded, so a root file named by an include loads once more and the
  /// cycle stops after that. Missing files are skipped.
  static func entries(files: [URL]) -> [Entry] {
    var result: [Entry] = []
    var includes: [URL] = []
    func read(_ file: URL) {
      guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return }
      for entry in entries(in: contents) {
        result.append(entry)
        guard entry.key == "config-file" else { continue }
        if entry.value.isEmpty {
          includes.removeAll()
        } else if let include = includeURL(entry.value, relativeTo: file) {
          includes.append(include)
        }
      }
    }

    for file in files {
      read(file.standardizedFileURL)
    }
    var loaded = Set<URL>()
    var index = 0
    while index < includes.count {
      let include = includes[index]
      index += 1
      guard loaded.insert(include).inserted else { continue }
      read(include)
    }
    return result
  }

  /// The `--key=value` launch arguments that Ghostty reads as configuration
  /// (`Config.loadCliArgs`). The first argument is the executable, and the
  /// arguments after `-e` are a command. The shell already removed any quotes.
  static func entries(arguments: [String]) -> [Entry] {
    var result: [Entry] = []
    for argument in arguments.dropFirst() {
      if argument == "-e" { break }
      guard argument.hasPrefix("--"), let separator = argument.firstIndex(of: "=") else { continue }
      let key = argument[argument.index(argument.startIndex, offsetBy: 2)..<separator]
      let value = argument[argument.index(after: separator)...]
      result.append(Entry(key: String(key), value: String(value)))
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

  /// The entries of one file. Like Ghostty, a leading UTF-8 byte order mark is
  /// skipped, a comment takes a full line, and quotes around a whole value are removed.
  static func entries(in contents: String) -> [Entry] {
    let text = contents.hasPrefix("\u{FEFF}") ? contents.dropFirst() : Substring(contents)
    return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
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
