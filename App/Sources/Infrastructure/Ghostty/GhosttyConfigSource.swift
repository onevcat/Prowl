import Foundation
import GhosttyKit

/// Where Prowl reads the user's Ghostty configuration from.
nonisolated enum GhosttyConfigSource: Equatable, Sendable {
  /// Ghostty's default config files, shared with standalone Ghostty.
  case ghosttyDefault
  /// One file that replaces Ghostty's default config files for Prowl only.
  case file(path: String)

  /// A blank or missing path selects Ghostty's default files.
  init(dedicatedPath: String?) {
    if let path = Self.normalizedPath(dedicatedPath) {
      self = .file(path: (path as NSString).expandingTildeInPath)
    } else {
      self = .ghosttyDefault
    }
  }

  /// Trims the value; a blank value means "no dedicated file".
  static func normalizedPath(_ path: String?) -> String? {
    guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  /// Loads the user's configuration into `config`, followed by its `config-file` includes.
  func load(into config: ghostty_config_t) {
    switch self {
    case .ghosttyDefault:
      ghostty_config_load_default_files(config)
    case .file(let path):
      // A missing dedicated file loads nothing, so Ghostty's built-in defaults apply.
      // Loading the shared files instead would break the isolation the user chose.
      if FileManager.default.fileExists(atPath: path) {
        path.withCString { ghostty_config_load_file(config, $0) }
      } else {
        ghosttyLogger.warning("Dedicated Ghostty config file not found: \(path)")
      }
    }
    ghostty_config_load_recursive_files(config)
  }

  /// The file that Open Config edits and that Prowl-only keys such as
  /// `prowl-split-divider-width` are read from. For the shared files this asks
  /// Ghostty, which creates its preferred file when none exists.
  var editableFilePath: String? {
    switch self {
    case .ghosttyDefault:
      GhosttyRuntime.ghosttyConfigPath()
    case .file(let path):
      path
    }
  }

  /// The files this source loads before their `config-file` includes, in load order.
  var userConfigFileURLs: [URL] {
    switch self {
    case .ghosttyDefault:
      GhosttyRuntime.defaultGhosttyConfigFileURLs()
    case .file(let path):
      [URL(fileURLWithPath: path)]
    }
  }
}
