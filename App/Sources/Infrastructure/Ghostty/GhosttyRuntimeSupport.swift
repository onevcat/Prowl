import AppKit
import GhosttyKit
import UniformTypeIdentifiers

nonisolated struct GhosttyThemePair: Equatable, Sendable {
  let light: String
  let dark: String
}

nonisolated enum GhosttyThemeMode: Equatable, Sendable {
  case none
  case single
  case dual

  /// Whether a tone mismatch with the app appearance should fall back to a
  /// default light/dark pair. A `.dual` theme is the user's explicit per-mode
  /// choice and is always respected; `.single` and `.none` are adapted so a
  /// light app never shows a dark terminal — `.none` because Ghostty's
  /// no-theme default is a fixed dark scheme that otherwise ignores the
  /// app appearance.
  var allowsMismatchFallback: Bool {
    switch self {
    case .single, .none:
      return true
    case .dual:
      return false
    }
  }
}

nonisolated enum GhosttyTerminalTone: Equatable, Sendable {
  case light
  case dark
  case unknown
}

nonisolated struct GhosttyUserConfigSnapshot: Equatable, Sendable {
  let themeMode: GhosttyThemeMode
  let backgroundTone: GhosttyTerminalTone

  static func parse(showConfigOutput: String) -> GhosttyUserConfigSnapshot {
    var themeSpec: String?
    var backgroundSpec: String?

    for rawLine in showConfigOutput.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      guard let separator = line.firstIndex(of: "=") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
      switch key {
      case "theme":
        themeSpec = value
      case "background":
        backgroundSpec = value
      default:
        continue
      }
    }

    let themeMode = parseThemeMode(from: themeSpec)
    let backgroundTone = classifyBackgroundTone(from: backgroundSpec)
    return .init(themeMode: themeMode, backgroundTone: backgroundTone)
  }

  static func parseThemeMode(from spec: String?) -> GhosttyThemeMode {
    guard let spec, !spec.isEmpty else { return .none }

    var hasLight = false
    var hasDark = false

    for rawPart in spec.split(separator: ",", omittingEmptySubsequences: true) {
      let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let separator = part.firstIndex(of: ":") else { continue }
      let key = part[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      switch key {
      case "light":
        hasLight = true
      case "dark":
        hasDark = true
      default:
        continue
      }
    }

    return (hasLight && hasDark) ? .dual : .single
  }

  static func classifyBackgroundTone(from spec: String?) -> GhosttyTerminalTone {
    // Decide "light or dark" purely from luminance. Popular dark themes
    // (Dracula, Nord, One Dark, Kanagawa, Solarized Dark, etc.) often have
    // noticeably tinted backgrounds, so gating on saturation misclassifies
    // them as unknown and defeats the whole fallback.
    guard let spec, let color = NSColor(ghosttyHexColor: spec) else { return .unknown }
    return classifyBackgroundTone(of: color)
  }

  static func classifyBackgroundTone(of color: NSColor) -> GhosttyTerminalTone {
    let luminance = color.luminance
    if luminance >= 0.65 {
      return .light
    }
    if luminance <= 0.35 {
      return .dark
    }
    return .unknown
  }
}

extension Notification.Name {
  static let ghosttyRuntimeConfigDidChange = Notification.Name("ghosttyRuntimeConfigDidChange")
}

extension NSColor {
  var ghosttyIsLightColor: Bool {
    luminance > 0.5
  }

  nonisolated var luminance: Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard let rgb = usingColorSpace(.sRGB) else { return 0 }
    rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (0.299 * red) + (0.587 * green) + (0.114 * blue)
  }

  nonisolated convenience init?(ghosttyHexColor: String) {
    let cleaned =
      ghosttyHexColor
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacing("#", with: "")
    guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
      return nil
    }

    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255
    self.init(red: red, green: green, blue: blue, alpha: 1)
  }

  nonisolated convenience init(ghostty: ghostty_config_color_s) {
    let red = Double(ghostty.r) / 255
    let green = Double(ghostty.g) / 255
    let blue = Double(ghostty.b) / 255
    self.init(red: red, green: green, blue: blue, alpha: 1)
  }
}

extension NSPasteboard.PasteboardType {
  init?(mimeType: String) {
    switch mimeType {
    case "text/plain":
      self = .string
      return
    default:
      break
    }
    guard let utType = UTType(mimeType: mimeType) else {
      self.init(mimeType)
      return
    }
    self.init(utType.identifier)
  }
}

extension NSPasteboard {
  static let ghosttyEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

  static func ghosttyEscape(_ str: String) -> String {
    var result = ""
    result.reserveCapacity(str.utf8.count)
    for char in str {
      if ghosttyEscapeCharacters.contains(char) { result.append("\\") }
      result.append(char)
    }
    return result
  }

  static var ghosttySelection: NSPasteboard = {
    NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
  }()

  func getOpinionatedStringContents() -> String? {
    if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
      return
        urls
        .map { $0.isFileURL ? Self.ghosttyEscape($0.path) : $0.absoluteString }
        .joined(separator: " ")
    }
    return string(forType: .string)
  }

  static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
    switch clipboard {
    case GHOSTTY_CLIPBOARD_STANDARD:
      return Self.general
    case GHOSTTY_CLIPBOARD_SELECTION:
      return Self.ghosttySelection
    default:
      return nil
    }
  }

  /// The pasteboard's representation of `mime`, read the way a paste reads it:
  /// `text/plain` goes through `getOpinionatedStringContents()` so copied files
  /// paste as shell-escaped paths. Other MIME types map to a pasteboard type
  /// through `UTType`.
  func ghosttyData(forMime mime: String) -> Data? {
    switch mime {
    case "text/plain":
      return getOpinionatedStringContents().map { Data($0.utf8) }
    default:
      guard let type = NSPasteboard.PasteboardType(mimeType: mime) else { return nil }
      return data(forType: type)
    }
  }

  /// The MIME types the pasteboard declares, without reading any data. Plain
  /// text and copied files both count as `text/plain`, matching
  /// `ghosttyData(forMime:)`.
  func ghosttyAvailableMimes() -> [String] {
    let declared = types ?? []
    var result: [String] = []
    var seen = Set<String>()
    if declared.contains(.string) || declared.contains(.fileURL) {
      result.append("text/plain")
      seen.insert("text/plain")
    }
    for type in declared {
      guard let mime = UTType(type.rawValue)?.preferredMIMEType else { continue }
      let normalized = mime == "text/plain;charset=utf-8" ? "text/plain" : mime
      guard seen.insert(normalized).inserted else { continue }
      result.append(normalized)
    }
    return result
  }
}

/// One clipboard representation crossing the libghostty boundary.
struct GhosttyClipboardContent: Equatable {
  var mime: String
  var data: Data
}

/// The owned copy of a clipboard read: the representations libghostty asked
/// for plus, when it asked for a listing, the declared MIME types.
struct GhosttyClipboardPayload: Equatable {
  var contents: [GhosttyClipboardContent]
  var available: [String]

  nonisolated init(contents: [GhosttyClipboardContent], available: [String]) {
    self.contents = contents
    self.available = available
  }

  /// Reads the requested representations from `pasteboard`. Duplicate MIME
  /// types are read once; types the pasteboard cannot serve are skipped.
  init(pasteboard: NSPasteboard, mimes: [String], list: Bool) {
    var contents: [GhosttyClipboardContent] = []
    var seen = Set<String>()
    for mime in mimes where seen.insert(mime).inserted {
      guard let data = pasteboard.ghosttyData(forMime: mime) else { continue }
      contents.append(GhosttyClipboardContent(mime: mime, data: data))
    }
    self.init(contents: contents, available: list ? pasteboard.ghosttyAvailableMimes() : [])
  }

  /// Copies the borrowed C payload of a confirmation request. Runs on the
  /// libghostty thread that owns the request, so it is not actor-isolated.
  nonisolated init(confirm: ghostty_clipboard_confirm_s) {
    var contents: [GhosttyClipboardContent] = []
    if let raw = confirm.contents {
      for index in 0..<confirm.contents_len {
        let item = raw[index]
        guard let mime = item.mime else { continue }
        let data: Data =
          if let bytes = item.data, item.len > 0 {
            Data(bytes: bytes, count: item.len)
          } else {
            Data()
          }
        contents.append(GhosttyClipboardContent(mime: String(cString: mime), data: data))
      }
    }
    var available: [String] = []
    if let raw = confirm.available {
      for index in 0..<confirm.available_len {
        guard let pointer = raw[index] else { continue }
        available.append(String(cString: pointer))
      }
    }
    self.init(contents: contents, available: available)
  }

  /// True when a non-empty `text/plain` representation is present: the paste
  /// changes the terminal, so it counts as editing activity.
  var hasText: Bool {
    contents.contains { $0.mime == "text/plain" && !$0.data.isEmpty }
  }
}
