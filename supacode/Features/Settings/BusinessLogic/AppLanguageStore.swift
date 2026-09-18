import Dependencies
import Foundation

/// Reads and writes the app language choice in the per-app `AppleLanguages` default, the
/// key that Foundation and AppKit consult at launch.
///
/// macOS writes the same key from System Settings → Language & Region → Applications, so
/// the Settings picker and System Settings always show one value and the last change
/// wins. Prowl keeps no second copy of the choice, which leaves nothing to reconcile.
///
/// Only the app domain is written (Debug and Release have separate bundle domains). The
/// global domain and other apps are never written.
nonisolated struct AppLanguageStore {
  static let appleLanguagesKey = "AppleLanguages"

  let defaults: UserDefaults
  /// The persistent domain of the app. Reads go through `persistentDomain(forName:)` so a
  /// command-line `-AppleLanguages` argument, which lives in the argument domain for one
  /// launch, is never mistaken for the saved choice.
  let domainName: String

  var appleLanguages: [String]? {
    defaults.persistentDomain(forName: domainName)?[Self.appleLanguagesKey] as? [String]
  }

  var language: AppLanguage {
    AppLanguage(appleLanguages: appleLanguages)
  }

  func setLanguage(_ language: AppLanguage) {
    if let appleLanguages = language.appleLanguages {
      defaults.set(appleLanguages, forKey: Self.appleLanguagesKey)
    } else {
      defaults.removeObject(forKey: Self.appleLanguagesKey)
    }
  }

  /// The system languages, without the per-app override. `Locale.preferredLanguages` cannot
  /// be used: it already has the override applied.
  static func systemLanguages(defaults: UserDefaults = .standard) -> [String] {
    defaults.persistentDomain(forName: UserDefaults.globalDomain)?[appleLanguagesKey] as? [String] ?? []
  }
}

nonisolated struct AppLanguageClient: Sendable {
  var current: @Sendable () -> AppLanguage = { .system }
  var set: @Sendable (_ language: AppLanguage) -> Void = { _ in }
  var systemLanguages: @Sendable () -> [String] = { [] }
}

extension AppLanguageClient: DependencyKey {
  static let liveValue: AppLanguageClient = {
    guard let domainName = Bundle.main.bundleIdentifier else { return AppLanguageClient() }
    return AppLanguageClient(
      current: { AppLanguageStore(defaults: .standard, domainName: domainName).language },
      set: { AppLanguageStore(defaults: .standard, domainName: domainName).setLanguage($0) },
      systemLanguages: { AppLanguageStore.systemLanguages() }
    )
  }()

  static let testValue = AppLanguageClient()
}

extension DependencyValues {
  var appLanguage: AppLanguageClient {
    get { self[AppLanguageClient.self] }
    set { self[AppLanguageClient.self] = newValue }
  }
}
