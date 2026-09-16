import Foundation

/// Applies the persisted language preference to the app-domain
/// `AppleLanguages` bridge, then snapshots whatever Bundle actually
/// negotiated. Call once before any localized UI is built.
///
/// Writing the persistent domain in this process cannot be assumed to
/// change this process: Foundation may already have cached the launch
/// language. The snapshot is therefore the real Bundle result, not the
/// preference we intended.
enum AppLanguageBootstrap {
  static func apply(preference: AppLanguage) -> ResolvedAppLanguage {
    if let domainName = Bundle.main.bundleIdentifier {
      AppLanguageBridge(defaults: .standard, domainName: domainName)
        .synchronize(preference: preference)
    }
    return snapshotEffectiveLanguage()
  }

  static func snapshotEffectiveLanguage() -> ResolvedAppLanguage {
    let supported = ResolvedAppLanguage.allCases.map(\.rawValue)
    let negotiated = Bundle.preferredLocalizations(
      from: supported,
      forPreferences: Bundle.main.preferredLocalizations
    ).first
    return negotiated.flatMap(ResolvedAppLanguage.init(rawValue:)) ?? .english
  }
}
