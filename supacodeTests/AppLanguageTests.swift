import Foundation
import Testing

@testable import supacode

struct AppLanguageTests {
  private let supportedLanguages = ["en", "zh-Hans"]

  // MARK: - Model

  @Test func rawValuesAreStableStorageIdentifiers() {
    #expect(AppLanguage.system.rawValue == "system")
    #expect(AppLanguage.zhHans.rawValue == "zh-Hans")
    #expect(AppLanguage.english.rawValue == "en")
    #expect(AppLanguage(rawValue: "future-language") == nil)
  }

  @Test func titlesUseNativeLanguageForms() {
    #expect(AppLanguage.system.title == "跟随系统")
    #expect(AppLanguage.zhHans.title == "简体中文")
    #expect(AppLanguage.english.title == "English")
  }

  @Test func resolvedLanguageIsOnlyEnOrZhHans() {
    #expect(Set(ResolvedAppLanguage.allCases.map(\.rawValue)) == ["en", "zh-Hans"])
  }

  @Test func bootstrapSnapshotIsASupportedLanguage() {
    let snapshot = AppLanguageBootstrap.snapshotEffectiveLanguage()
    #expect(ResolvedAppLanguage.allCases.contains(snapshot))
  }

  // MARK: - Resolution

  @Test func explicitPreferenceWinsOverPlatformLanguages() {
    #expect(
      AppLanguageResolver.resolve(
        preference: .english,
        platformLanguages: ["zh-Hans"],
        supportedLanguages: supportedLanguages
      ) == .english
    )
    #expect(
      AppLanguageResolver.resolve(
        preference: .zhHans,
        platformLanguages: ["en-US"],
        supportedLanguages: supportedLanguages
      ) == .zhHans
    )
  }

  @Test func systemPreferenceFollowsPlatformNegotiation() {
    #expect(
      AppLanguageResolver.resolve(
        preference: .system,
        platformLanguages: ["zh-Hans", "en"],
        supportedLanguages: supportedLanguages
      ) == .zhHans
    )
    #expect(
      AppLanguageResolver.resolve(
        preference: .system,
        platformLanguages: ["en-US", "zh-Hans"],
        supportedLanguages: supportedLanguages
      ) == .english
    )
  }

  @Test func systemPreferenceFallsBackToEnglishWhenNothingMatches() {
    #expect(
      AppLanguageResolver.resolve(
        preference: .system,
        platformLanguages: ["fr-FR"],
        supportedLanguages: supportedLanguages
      ) == .english
    )
    #expect(
      AppLanguageResolver.resolve(
        preference: .system,
        platformLanguages: [],
        supportedLanguages: supportedLanguages
      ) == .english
    )
  }

  @Test func traditionalChineseDoesNotResolveToSimplified() {
    // Script differs, so platform matching must fall back to English rather
    // than treating any "zh" prefix as Simplified.
    #expect(
      AppLanguageResolver.resolve(
        preference: .system,
        platformLanguages: ["zh-Hant-TW"],
        supportedLanguages: supportedLanguages
      ) == .english
    )
  }

  @Test func commandLineOverrideBeatsExplicitPreference() {
    #expect(
      AppLanguageResolver.resolve(
        preference: .zhHans,
        platformLanguages: ["zh-Hans"],
        supportedLanguages: supportedLanguages,
        commandLineOverride: ["en"]
      ) == .english
    )
    #expect(
      AppLanguageResolver.resolve(
        preference: .english,
        platformLanguages: ["en"],
        supportedLanguages: supportedLanguages,
        commandLineOverride: ["zh-Hans"]
      ) == .zhHans
    )
  }

  @Test func commandLineOverrideWithoutMatchFallsBackToEnglish() {
    #expect(
      AppLanguageResolver.resolve(
        preference: .system,
        platformLanguages: ["zh-Hans"],
        supportedLanguages: supportedLanguages,
        commandLineOverride: ["fr-FR"]
      ) == .english
    )
  }

  // MARK: - Bridge ownership

  @Test func firstExplicitSelectionRecordsMissingOriginalAndRestoresByRemovingKey() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)

    bridge.synchronize(preference: .zhHans)
    #expect(bridge.currentAppleLanguages == ["zh-Hans"])

    // The key did not exist before Prowl took over, so restoring "system"
    // removes it rather than resurrecting a phantom value.
    bridge.synchronize(preference: .system)
    #expect(bridge.currentAppleLanguages == nil)
  }

  @Test func existingExternalOverrideIsRestoredOnReturnToSystem() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    defaults.set(["ja"], forKey: "AppleLanguages")
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)

    bridge.synchronize(preference: .english)
    #expect(bridge.currentAppleLanguages == ["en"])

    bridge.synchronize(preference: .system)
    #expect(bridge.currentAppleLanguages == ["ja"])
  }

  @Test func externalModificationInSystemModeIsPreservedAndRecordCleared() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)

    bridge.synchronize(preference: .zhHans)
    #expect(bridge.currentAppleLanguages == ["zh-Hans"])

    // The user changes the per-app language through System Settings while
    // Prowl's record still points at its own write.
    defaults.set(["fr"], forKey: "AppleLanguages")
    bridge.synchronize(preference: .system)

    // The external value wins; the stale record must be dropped so a later
    // explicit selection treats "fr" as the value to restore.
    #expect(bridge.currentAppleLanguages == ["fr"])
    bridge.synchronize(preference: .english)
    #expect(bridge.currentAppleLanguages == ["en"])
    bridge.synchronize(preference: .system)
    #expect(bridge.currentAppleLanguages == ["fr"])
  }

  @Test func externalModificationInExplicitModeBecomesNewRestoreTarget() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)

    bridge.synchronize(preference: .zhHans)
    defaults.set(["fr"], forKey: "AppleLanguages")

    bridge.synchronize(preference: .english)
    #expect(bridge.currentAppleLanguages == ["en"])

    bridge.synchronize(preference: .system)
    #expect(bridge.currentAppleLanguages == ["fr"])
  }

  @Test func systemWithoutRecordNeverClaimsExistingKey() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    // A per-app override set outside Prowl, with no Prowl ownership record.
    defaults.set(["de"], forKey: "AppleLanguages")
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)

    bridge.synchronize(preference: .system)
    #expect(bridge.currentAppleLanguages == ["de"])
  }

  @Test func switchingBetweenExplicitLanguagesKeepsOriginalRestoreTarget() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)

    bridge.synchronize(preference: .zhHans)
    bridge.synchronize(preference: .english)
    #expect(bridge.currentAppleLanguages == ["en"])

    // The original value was "absent" — Prowl's own zh-Hans write must not
    // become the restore target just because it is the current value.
    bridge.synchronize(preference: .system)
    #expect(bridge.currentAppleLanguages == nil)
  }

  @Test func predictionStripsProwlDerivedPrefixFromPreferredLanguages() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)
    bridge.synchronize(preference: .zhHans)

    #expect(
      bridge.platformLanguagesForPrediction(preferredLanguages: ["zh-Hans", "en"]) == ["en"]
    )
  }

  @Test func predictionKeepsExternalOverrideAsSystemInput() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    defaults.set(["fr"], forKey: "AppleLanguages")
    let bridge = AppLanguageBridge(defaults: defaults, domainName: suite)

    #expect(
      bridge.platformLanguagesForPrediction(preferredLanguages: ["fr", "en"]) == ["fr", "en"]
    )
  }

  private func makeIsolatedDefaults(
    function: String = #function
  ) -> (UserDefaults, String) {
    let suite = "prowl-app-language-tests.\(function).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }
}
