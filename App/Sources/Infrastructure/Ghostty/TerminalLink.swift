import Foundation
import UniformTypeIdentifiers

/// A link that terminal output asked to open: an OSC 8 hyperlink, or text that
/// a `link` config entry matched (Ghostty's `unknown` kind). Any program can
/// print one, so it must not reach Launch Services unchecked.
///
/// libghostty 1.4 refuses to open these kinds itself on macOS and expects the
/// embedder to check them. The policy follows Ghostty's macOS `UntrustedURL`
/// (advisories GHSA-cw69-wm67-5pv8 and GHSA-mfw9-xcr3-7gfp), which Prowl does
/// not embed.
nonisolated struct TerminalLink: Equatable, Sendable {
  enum DenialReason: Equatable, Sendable {
    case malformedURL
    case unsafeCharacters
    case invalidWebURL
    case inaccessibleFile
    case unsafeFile

    var message: String {
      switch self {
      case .malformedURL:
        String(localized: "The target is not an absolute URL with a scheme.")
      case .unsafeCharacters:
        String(localized: "The target contains invisible or line-breaking characters.")
      case .invalidWebURL:
        String(localized: "The web target does not contain a valid host.")
      case .inaccessibleFile:
        String(localized: "The local target does not exist or is not a regular file or folder.")
      case .unsafeFile:
        String(localized: "Opening this local target could run code.")
      }
    }
  }

  enum Decision: Equatable, Sendable {
    /// Schemes with well-understood behavior that runs no code: open directly.
    case allow(URL)
    /// A custom scheme dispatches to whatever app registered it: ask first.
    case confirm(URL)
    /// Never dispatch malformed targets or local files that could run code.
    case deny(DenialReason)
  }

  let string: String

  init(_ string: String) {
    self.string = string
  }

  /// The target for a value of Ghostty's `unknown` kind. Unlike an OSC 8 URI,
  /// such a value may be a plain path (`~/notes.txt`, `/tmp/log`), which is
  /// checked as a file URL. A value with unsafe characters stays unchanged so
  /// percent-encoding cannot hide them from the check.
  init(unknownKindValue value: String) {
    if URL(string: value)?.scheme != nil || Self.containsUnsafeCharacters(value) {
      self.init(value)
    } else {
      let path = NSString(string: value).standardizingPath
      self.init(URL(filePath: path).absoluteString)
    }
  }

  var decision: Decision {
    guard !string.isEmpty else { return .deny(.malformedURL) }

    // Foundation accepts control and formatting characters that AppKit can
    // render as line breaks, zero-width text, or bidirectional overrides.
    guard !Self.containsUnsafeCharacters(string) else {
      return .deny(.unsafeCharacters)
    }

    // An explicit scheme keeps a relative reference from being read as a
    // local path by a later layer.
    guard
      let url = URL(string: string),
      let scheme = url.scheme?.lowercased(),
      !scheme.isEmpty
    else {
      return .deny(.malformedURL)
    }

    switch scheme {
    case "http", "https":
      // "https:relative" has a scheme but no authority, and handlers may
      // resolve it against different base URLs.
      guard let host = url.host(), !host.isEmpty else {
        return .deny(.invalidWebURL)
      }
      return .allow(url)

    case "mailto":
      // A bare "mailto:" would open an empty message.
      guard
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        !components.path.isEmpty
      else {
        return .deny(.malformedURL)
      }
      return .allow(url)

    case "file":
      return Self.fileDecision(for: url)

    default:
      return .confirm(url)
    }
  }

  /// A single-line form of the effective target for the alert. File URLs are
  /// shown exactly as they are opened (standardized, symlinks and aliases
  /// resolved), so traversal, padding, and aliases cannot make the shown and
  /// opened targets differ.
  var displayString: String {
    let normalized: String
    if let url = URL(string: string), url.scheme != nil {
      if url.isFileURL {
        let effective = Self.effectiveFileURL(url) ?? url.standardizedFileURL.resolvingSymlinksInPath()
        normalized = effective.path(percentEncoded: false)
      } else {
        normalized = string
      }
    } else {
      normalized = URL(filePath: string).standardizedFileURL.path(percentEncoded: false)
    }
    // Escape after normalizing so an unsafe scalar shows as text and cannot
    // start a second line.
    var result = ""
    for scalar in normalized.unicodeScalars {
      if Self.isUnsafeCharacter(scalar) {
        result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  static func containsUnsafeCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: isUnsafeCharacter)
  }
}

nonisolated extension TerminalLink {
  fileprivate static func fileDecision(for url: URL) -> Decision {
    // A query or fragment names no part of a file, and handlers read them
    // inconsistently.
    guard url.isFileURL, url.query() == nil, url.fragment() == nil else {
      return .deny(.malformedURL)
    }
    // Only this machine: a remote host could trigger network access.
    if let host = url.host(), !host.isEmpty, host.caseInsensitiveCompare("localhost") != .orderedSame {
      return .deny(.malformedURL)
    }

    // Classify the effective object, not the spelling in the output, so a
    // harmless-looking symlink or Finder alias cannot hide an executable
    // target.
    guard let canonicalURL = effectiveFileURL(url) else {
      return .deny(.inaccessibleFile)
    }
    let values: URLResourceValues
    do {
      values = try canonicalURL.resourceValues(forKeys: [
        .contentTypeKey,
        .isDirectoryKey,
        .isExecutableKey,
        .isRegularFileKey,
      ])
    } catch {
      return .deny(.inaccessibleFile)
    }
    // Devices, sockets, and other special objects are never opened.
    guard values.isDirectory == true || values.isRegularFile == true else {
      return .deny(.inaccessibleFile)
    }
    guard !isUnsafeFile(canonicalURL, values: values) else {
      return .deny(.unsafeFile)
    }
    return .allow(canonicalURL)
  }

  /// The file a local URL finally names: standardized, symlinks resolved,
  /// and Finder aliases followed. An alias needs no executable bit, yet
  /// Launch Services opens its target, so an alias to an app must be judged
  /// as the app. `nil` when an alias cannot be resolved without UI or
  /// mounting, or the chain is too long.
  fileprivate static func effectiveFileURL(_ url: URL) -> URL? {
    var current = url.standardizedFileURL.resolvingSymlinksInPath()
    for _ in 0..<8 {
      // A missing file has no resource values; the caller reports it.
      guard (try? current.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true else {
        return current
      }
      guard let target = try? URL(resolvingAliasFileAt: current, options: [.withoutUI, .withoutMounting]) else {
        return nil
      }
      current = target.standardizedFileURL.resolvingSymlinksInPath()
    }
    return nil
  }

  fileprivate static func isUnsafeFile(_ url: URL, values: URLResourceValues) -> Bool {
    // Launch Services picks a handler by extension, so block executable
    // containers even when their executable bit is clear.
    if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
      return true
    }
    // Content types catch a missing or misleading extension, including
    // subtypes such as shell scripts and application bundles.
    if let type = values.contentType, unsafeContentTypes.contains(where: { type.conforms(to: $0) }) {
      return true
    }
    return values.isDirectory != true && values.isExecutable == true
  }

  fileprivate static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    // C0 and C1 controls, including CR, LF, and NEL.
    case 0x00...0x1F, 0x7F...0x9F:
      true
    // Directional marks and zero-width characters can reorder or hide text.
    case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
      true
    // Line and paragraph separators start new lines in AppKit text.
    case 0x2028...0x2029:
      true
    // Word joiner and byte order mark: invisible padding.
    case 0x2060, 0xFEFF:
      true
    default:
      false
    }
  }

  fileprivate static let unsafePathExtensions: Set<String> = [
    "action",
    "app",
    "applescript",
    "class",
    "command",
    "desktop",
    "inetloc",
    "jar",
    "mobileconfig",
    "mpkg",
    "pkg",
    "scpt",
    "terminal",
    "tool",
    "url",
    "webloc",
    "workflow",
  ]

  fileprivate static let unsafeContentTypes: [UTType] = [
    .application,
    .executable,
    .script,
  ]
}
