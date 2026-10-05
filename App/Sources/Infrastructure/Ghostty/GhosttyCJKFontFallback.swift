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
    "U+2E80-U+2FDF",  // CJK Radicals Supplement, Kangxi Radicals
    "U+3000-U+303F",  // CJK Symbols and Punctuation
    "U+3040-U+30FF",  // Hiragana, Katakana
    "U+3100-U+312F",  // Bopomofo
    "U+3190-U+31FF",  // Kanbun, Bopomofo Extended, CJK Strokes, Katakana Phonetic Extensions
    "U+3200-U+33FF",  // Enclosed CJK Letters and Months, CJK Compatibility
    "U+3400-U+4DBF",  // CJK Unified Ideographs Extension A
    "U+4E00-U+9FFF",  // CJK Unified Ideographs
    "U+F900-U+FAFF",  // CJK Compatibility Ideographs
    "U+FE30-U+FE4F",  // CJK Compatibility Forms
    "U+FF00-U+FFEF",  // Halfwidth and Fullwidth Forms
  ]

  /// Hangul Jamo, Compatibility Jamo, Jamo Extended-A/B, and syllables.
  static let hangulRanges = [
    "U+1100-U+11FF",
    "U+3130-U+318F",
    "U+A960-U+A97F",
    "U+AC00-U+D7AF",
    "U+D7B0-U+D7FF",
  ]

  /// The config lines Prowl adds, or `nil` when the user's config sets a font. A mapped
  /// font that lacks a codepoint is skipped by Ghostty, so the normal fallback still
  /// covers the gaps.
  static func overrideContents(
    userConfigFiles: [URL],
    arguments: [String] = [],
    preferredLanguages: [String]
  ) -> String? {
    guard !configuresFont(files: userConfigFiles, arguments: arguments) else { return nil }
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

  /// Whether the config sets `font-family` or `font-codepoint-map`: `files` and their
  /// `config-file` includes as Ghostty loads them, then the launch `arguments`, which Ghostty
  /// reads after the files. A blank value clears the list, as in Ghostty.
  /// `ghostty_config_get` cannot read these repeatable keys, so this reads the raw text.
  static func configuresFont(files: [URL], arguments: [String] = []) -> Bool {
    var familyCount = 0
    var codepointMapCount = 0
    for entry in GhosttyRawConfig.entries(files: files) + GhosttyRawConfig.entries(arguments: arguments) {
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
}
