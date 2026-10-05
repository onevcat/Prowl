import Foundation

/// Prowl's CJK font mapping for a Ghostty config that sets no font.
///
/// Ghostty asks CoreText for a system-language font only for CJK ideographs. For kana, CJK
/// punctuation, and fullwidth forms it scores every installed font and prefers fonts that
/// claim to be monospace, such as BIZ UDGothic, BIZ UDMincho, or Osaka-Mono. The first
/// face it loads also serves the ideographs that follow, and each fallback face has its own
/// size adjustment, so CJK text changes face and size within one line. Mapping the CJK
/// ranges to the system CJK font keeps one face and one size.
nonisolated enum GhosttyCJKFontFallback {
  static let hangulFamily = "Apple SD Gothic Neo"

  /// Kana, CJK punctuation, ideographs, and fullwidth forms.
  static let cjkRanges = [
    "U+2E80-U+2FFF",  // CJK Radicals Supplement, Kangxi Radicals, Ideographic Description
    "U+3000-U+303F",  // CJK Symbols and Punctuation
    "U+3040-U+30FF",  // Hiragana, Katakana
    "U+3100-U+312F",  // Bopomofo
    "U+3190-U+31FF",  // Kanbun, Bopomofo Extended, CJK Strokes, Katakana Phonetic Extensions
    "U+3200-U+33FF",  // Enclosed CJK Letters and Months, CJK Compatibility
    "U+3400-U+4DBF",  // CJK Unified Ideographs Extension A
    "U+4E00-U+9FFF",  // CJK Unified Ideographs
    "U+F900-U+FAFF",  // CJK Compatibility Ideographs
    "U+FE10-U+FE1F",  // Vertical Forms
    "U+FE30-U+FE4F",  // CJK Compatibility Forms
    "U+FF00-U+FF9F",  // Fullwidth forms and halfwidth katakana
    "U+FFE0-U+FFEF",  // Fullwidth and halfwidth symbols
    "U+1AFF0-U+1B16F",  // Kana Extended-A/B, Kana Supplement, Small Kana Extension
    "U+20000-U+323AF",  // CJK Unified Ideographs Extension B-H, Compatibility Ideographs Supplement
  ]

  /// Hangul Jamo, Compatibility Jamo, Jamo Extended-A/B, syllables, and halfwidth Hangul.
  static let hangulRanges = [
    "U+1100-U+11FF",
    "U+3130-U+318F",
    "U+A960-U+A97F",
    "U+AC00-U+D7AF",
    "U+D7B0-U+D7FF",
    "U+FFA0-U+FFDC",
  ]

  /// The config lines Prowl adds, or `nil` when the user's config sets a font. A mapped
  /// font that lacks a codepoint is skipped by Ghostty, so the normal fallback still
  /// covers the gaps.
  static func overrideContents(
    userConfigFiles: [URL],
    arguments: [String] = [],
    themeDirectories: [URL] = [],
    preferredLanguages: [String]
  ) -> String? {
    guard !configuresFont(files: userConfigFiles, arguments: arguments, themeDirectories: themeDirectories) else {
      return nil
    }
    let family = cjkFamily(preferredLanguages: preferredLanguages)
    return """
      font-codepoint-map = \(cjkRanges.joined(separator: ","))=\(family)
      font-codepoint-map = \(hangulRanges.joined(separator: ","))=\(hangulFamily)
      """
  }

  /// The languages that pick the CJK font: a `-AppleLanguages` launch argument, else
  /// the system languages, else the process languages. Prowl's own app-language
  /// setting does not count, so a Japanese system with an English Prowl UI still
  /// gets Hiragino Sans.
  static func preferredLanguages(defaults: UserDefaults = .standard) -> [String] {
    let argumentLanguages =
      defaults.volatileDomain(forName: UserDefaults.argumentDomain)[AppLanguageStore.appleLanguagesKey]
      as? [String]
    return preferredLanguages(
      argumentLanguages: argumentLanguages,
      systemLanguages: AppLanguageStore.systemLanguages(defaults: defaults),
      processLanguages: Locale.preferredLanguages
    )
  }

  static func preferredLanguages(
    argumentLanguages: [String]?,
    systemLanguages: [String],
    processLanguages: [String]
  ) -> [String] {
    if let argumentLanguages, !argumentLanguages.isEmpty { return argumentLanguages }
    if !systemLanguages.isEmpty { return systemLanguages }
    return processLanguages
  }

  /// The family that CoreText returns for ideographs under `languages`: the first CJK
  /// language decides, and Simplified Chinese applies when there is none.
  static func cjkFamily(preferredLanguages languages: [String]) -> String {
    for identifier in languages {
      let language = Locale.Language(identifier: identifier)
      switch language.languageCode?.identifier {
      case "ja":
        return "Hiragino Sans"
      case "ko":
        return hangulFamily
      case "zh":
        return chineseFamily(language)
      default:
        continue
      }
    }
    return "PingFang SC"
  }

  private static func chineseFamily(_ language: Locale.Language) -> String {
    let script = language.script?.identifier
    let region = language.region?.identifier
    if script == "Hans" { return "PingFang SC" }
    if region == "HK" || region == "MO" { return "PingFang HK" }
    if script == "Hant" || region == "TW" { return "PingFang TC" }
    return "PingFang SC"
  }

  /// Whether the config sets `font-family` or `font-codepoint-map`. The user's entries are
  /// `files` and their `config-file` includes as Ghostty loads them, then the launch
  /// `arguments`. The active theme can set a font too; Ghostty loads it first, so the user's
  /// entries come after it. With a light/dark pair, a font in either theme counts.
  /// `ghostty_config_get` cannot read these repeatable keys, so this reads the raw text.
  static func configuresFont(files: [URL], arguments: [String] = [], themeDirectories: [URL] = []) -> Bool {
    let userEntries = GhosttyRawConfig.entries(files: files) + GhosttyRawConfig.entries(arguments: arguments)
    let themeFiles =
      userEntries.last { $0.key == "theme" }
      .map { themeFileURLs(spec: $0.value, directories: themeDirectories) } ?? []
    guard !themeFiles.isEmpty else { return setsFont(userEntries) }
    return themeFiles.contains { theme in
      // A theme file cannot name other files, so its `config-file` lines are not followed.
      let contents = (try? String(contentsOf: theme, encoding: .utf8)) ?? ""
      return setsFont(GhosttyRawConfig.entries(in: contents) + userEntries)
    }
  }

  /// Whether `font-family` or `font-codepoint-map` holds a value after `entries`, where a
  /// blank value clears the list, as in Ghostty.
  private static func setsFont(_ entries: [GhosttyRawConfig.Entry]) -> Bool {
    var familyCount = 0
    var codepointMapCount = 0
    for entry in entries {
      switch entry.key {
      case "font-family":
        familyCount = entry.value.isEmpty ? 0 : familyCount + 1
      case "font-codepoint-map":
        codepointMapCount = entry.value.isEmpty ? 0 : codepointMapCount + 1
      default:
        continue
      }
    }
    return familyCount > 0 || codepointMapCount > 0
  }

  /// The theme files for a `theme` value, found like Ghostty: an absolute path is used as
  /// is, and a name is looked up in `directories` in order. A value with `,`, `:`, or `=`
  /// is a light/dark pair. A blank value means no theme.
  static func themeFileURLs(spec: String, directories: [URL]) -> [URL] {
    let names: [String]
    if spec.contains(where: { $0 == "," || $0 == ":" || $0 == "=" }) {
      names = spec.split(separator: ",").compactMap { part in
        guard let separator = part.firstIndex(where: { $0 == ":" || $0 == "=" }) else { return nil }
        let key = part[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "light" || key == "dark" else { return nil }
        return part[part.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      }
    } else {
      names = [spec.trimmingCharacters(in: .whitespaces)]
    }
    return names.filter { !$0.isEmpty }.compactMap { name in
      if name.hasPrefix("/") {
        return FileManager.default.fileExists(atPath: name) ? URL(fileURLWithPath: name) : nil
      }
      return directories.map { $0.appending(path: name) }
        .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
  }
}
