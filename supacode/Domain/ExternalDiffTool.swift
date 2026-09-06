import Foundation
import ProwlCLIShared

nonisolated enum ExternalDiffLaunchMode: Equatable, Sendable {
  case builtIn
  case terminal
  case gui
}

nonisolated enum ExternalDiffTool: String, CaseIterable, Identifiable, Codable, Sendable {
  case builtIn = "built-in"
  case hunk
  case fileMerge = "filemerge"
  case kaleidoscope
  case custom

  var id: String { settingsID }

  var settingsID: String { rawValue }

  var title: String {
    switch self {
    case .builtIn: "Built-in"
    case .hunk: "Hunk"
    case .fileMerge: "FileMerge"
    case .kaleidoscope: "Kaleidoscope"
    case .custom: "Custom Command"
    }
  }

  var launchMode: ExternalDiffLaunchMode {
    switch self {
    case .builtIn:
      .builtIn
    case .hunk:
      .terminal
    case .fileMerge, .kaleidoscope, .custom:
      .gui
    }
  }

  var defaultCommandName: String? {
    switch self {
    case .fileMerge:
      "opendiff"
    case .kaleidoscope:
      "ksdiff"
    case .hunk:
      "hunk"
    case .builtIn, .custom:
      nil
    }
  }

  var isInstalled: Bool {
    switch self {
    case .builtIn, .custom:
      true
    case .fileMerge:
      ExternalDiffToolPathResolver.executableExists("opendiff")
    case .kaleidoscope:
      ExternalDiffToolPathResolver.executableExists("ksdiff")
    case .hunk:
      ExternalDiffToolPathResolver.executableExists("hunk")
    }
  }

  static var menuOrder: [ExternalDiffTool] {
    [.builtIn, .hunk, .fileMerge, .kaleidoscope, .custom]
  }

  static var availableCases: [ExternalDiffTool] {
    menuOrder.filter(\.isInstalled)
  }

  static var settingsMenuCases: [ExternalDiffTool] {
    menuOrder
  }

  static func fromSettingsID(_ settingsID: String?) -> ExternalDiffTool {
    guard let settingsID,
      let tool = Self(rawValue: settingsID),
      tool.isInstalled
    else {
      return .builtIn
    }
    return tool
  }

  static func normalizedSettingsID(_ settingsID: String?) -> String {
    fromSettingsID(settingsID).settingsID
  }
}

nonisolated struct ExternalDiffSettings: Equatable, Sendable {
  var toolID: String
  var customCommand: String

  var tool: ExternalDiffTool {
    ExternalDiffTool(rawValue: toolID) ?? .builtIn
  }
}

nonisolated struct ExternalDiffCommandContext: Equatable, Sendable {
  let worktreePath: String
  let repoPath: String
  let branch: String
  let leftPath: String
  let rightPath: String
}

nonisolated enum ExternalDiffCommandTemplate {
  static func render(_ template: String, context: ExternalDiffCommandContext) -> String {
    let replacements = [
      "{worktreePath}": shellQuoted(context.worktreePath),
      "{repoPath}": shellQuoted(context.repoPath),
      "{branch}": shellQuoted(context.branch),
      "{leftPath}": shellQuoted(context.leftPath),
      "{rightPath}": shellQuoted(context.rightPath),
    ]
    return replacements.reduce(template) { partial, replacement in
      partial.replacing(replacement.key, with: replacement.value)
    }
  }

  static func shellQuoted(_ value: String) -> String {
    "'\(value.replacing("'", with: "'\"'\"'"))'"
  }
}

nonisolated enum ExternalDiffToolPathResolver {
  static func executableExists(_ name: String) -> Bool {
    executableURL(named: name) != nil
  }

  static func executableURL(named name: String) -> URL? {
    for directory in executableSearchPaths {
      let url = URL(fileURLWithPath: directory).appending(path: name)
      if FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) {
        return url
      }
    }
    return nil
  }

  private static var executableSearchPaths: [String] {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let environmentPaths = path.split(separator: ":").map(String.init)
    return environmentPaths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
  }
}
