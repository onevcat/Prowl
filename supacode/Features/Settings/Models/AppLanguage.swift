import Foundation

/// The persisted language preference. Raw values are stable storage
/// identifiers for `settings.json` — never store display text.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
  case system
  case zhHans = "zh-Hans"
  case english = "en"

  var id: String {
    rawValue
  }

  /// Each option named in its own language, so a user who picked a language
  /// they cannot read can still find their way back.
  var title: String {
    switch self {
    case .system:
      return "Follow System / 跟随系统"
    case .zhHans:
      return "简体中文"
    case .english:
      return "English"
    }
  }
}

/// The outcome of resolving a preference against the platform's language
/// list — the set of languages Prowl actually ships localizations for.
enum ResolvedAppLanguage: String, CaseIterable, Codable, Sendable {
  case english = "en"
  case zhHans = "zh-Hans"
}

enum AppLanguageResolver {
  /// Resolves the effective language with a fixed priority: command-line
  /// override (this launch only) > explicit preference > platform language
  /// negotiation > English fallback. Matching is delegated to the platform
  /// (`Bundle.preferredLocalizations(from:forPreferences:)`) rather than
  /// hand-rolled "any zh prefix means Simplified" rules.
  ///
  /// - Parameters:
  ///   - preference: The persisted preference from `GlobalSettings.appLanguage`.
  ///   - platformLanguages: Preferred languages with any Prowl-managed
  ///     `AppleLanguages` override already removed by the caller.
  ///   - supportedLanguages: Localizations the app ships, in fallback order.
  ///   - commandLineOverride: Optional `-AppleLanguages` argument value; it
  ///     participates in resolution but is never written back to settings.
  /// - Returns: The language the app UI should use.
  static func resolve(
    preference: AppLanguage,
    platformLanguages: [String],
    supportedLanguages: [String],
    commandLineOverride: [String]? = nil
  ) -> ResolvedAppLanguage {
    let supported =
      supportedLanguages.isEmpty
      ? ResolvedAppLanguage.allCases.map(\.rawValue)
      : supportedLanguages
    if let commandLineOverride, !commandLineOverride.isEmpty {
      return match(preferences: commandLineOverride, supported: supported) ?? .english
    }
    switch preference {
    case .zhHans:
      return .zhHans
    case .english:
      return .english
    case .system:
      guard !platformLanguages.isEmpty else { return .english }
      return match(preferences: platformLanguages, supported: supported) ?? .english
    }
  }

  private static func match(preferences: [String], supported: [String]) -> ResolvedAppLanguage? {
    guard let matched = Bundle.preferredLocalizations(from: supported, forPreferences: preferences).first
    else {
      return nil
    }
    return ResolvedAppLanguage(rawValue: matched)
  }
}
