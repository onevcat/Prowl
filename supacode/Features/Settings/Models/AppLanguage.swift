import Foundation

/// The language choice shown in Settings. Prowl keeps no copy of it: the per-app
/// `AppleLanguages` default is the only source (see `AppLanguageStore`).
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
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

  /// Reads the choice from a per-app `AppleLanguages` value. macOS writes the same key from
  /// System Settings → Language & Region → Applications, with regional identifiers and a
  /// fallback list, so the value is negotiated the way the platform does it. A language
  /// Prowl has no localization for reads as English, because that is what the app shows.
  init(appleLanguages: [String]?) {
    guard let appleLanguages, !appleLanguages.isEmpty else {
      self = .system
      return
    }
    let resolved = AppLanguageResolver.match(
      preferences: appleLanguages,
      supported: ResolvedAppLanguage.allCases.map(\.rawValue)
    )
    self = resolved == .zhHans ? .zhHans : .english
  }

  /// The per-app `AppleLanguages` value for this choice. `nil` removes the key, so the app
  /// follows the system language again.
  var appleLanguages: [String]? {
    self == .system ? nil : [rawValue]
  }
}

/// The languages Prowl ships localizations for.
nonisolated enum ResolvedAppLanguage: String, CaseIterable, Sendable {
  case english = "en"
  case zhHans = "zh-Hans"

  /// The language this process runs in. Foundation negotiates it once at launch, so a later
  /// change of the choice does not affect it.
  static func effective(bundle: Bundle = .main) -> ResolvedAppLanguage {
    AppLanguageResolver.match(
      preferences: bundle.preferredLocalizations,
      supported: allCases.map(\.rawValue)
    ) ?? .english
  }
}

nonisolated enum AppLanguageResolver {
  /// Predicts the language of the next normal launch: an explicit choice wins, and
  /// "Follow System" negotiates the system languages. Matching is delegated to the
  /// platform (`Bundle.preferredLocalizations(from:forPreferences:)`) rather than
  /// hand-rolled "any zh prefix means Simplified" rules.
  ///
  /// - Parameters:
  ///   - preference: The current choice.
  ///   - platformLanguages: The system languages, without the per-app override.
  ///   - supportedLanguages: Localizations the app ships, in fallback order.
  static func resolve(
    preference: AppLanguage,
    platformLanguages: [String],
    supportedLanguages: [String]
  ) -> ResolvedAppLanguage {
    switch preference {
    case .zhHans:
      return .zhHans
    case .english:
      return .english
    case .system:
      let supported =
        supportedLanguages.isEmpty
        ? ResolvedAppLanguage.allCases.map(\.rawValue)
        : supportedLanguages
      guard !platformLanguages.isEmpty else { return .english }
      return match(preferences: platformLanguages, supported: supported) ?? .english
    }
  }

  static func match(preferences: [String], supported: [String]) -> ResolvedAppLanguage? {
    guard let matched = Bundle.preferredLocalizations(from: supported, forPreferences: preferences).first
    else {
      return nil
    }
    return ResolvedAppLanguage(rawValue: matched)
  }
}
