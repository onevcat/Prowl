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
    #expect(AppLanguage.system.title == "Follow System / 跟随系统")
    #expect(AppLanguage.zhHans.title == "简体中文")
    #expect(AppLanguage.english.title == "English")
  }

  @Test func chinesePullRequestSummaryPreservesBaseAndHeadRoles() throws {
    let template = try chinese("%@ wants to merge %@ %@ into %@ from %@")
    let summary = String(format: template, "alice", "2", "commits", "main", "feature")

    #expect(summary == "alice 想要将 2 commits 从 feature 合并到 main")
  }

  @Test func chineseSkillRemovalHelpPreservesSkillAndPathRoles() throws {
    let template = try chinese("Remove the %@ skill link at %@; the bundled skill stays in the app")
    let help = String(format: template, "reviewer", "/tmp/reviewer")

    #expect(help == "移除 /tmp/reviewer 处的 reviewer 技能链接；内置技能仍保留在应用中")
  }

  @Test func confirmedWorkflowUIStringsHaveChineseTranslations() throws {
    let expectedTranslations = [
      "Delete Run": "删除运行记录",
      "Workflow run options": "工作流运行选项",
      "No fields": "无字段",
    ]

    for (key, expected) in expectedTranslations {
      #expect(try chinese(key) == expected)
    }
  }

  @Test func resolvedLanguageIsOnlyEnOrZhHans() {
    #expect(Set(ResolvedAppLanguage.allCases.map(\.rawValue)) == ["en", "zh-Hans"])
  }

  @Test func effectiveLanguageIsASupportedLanguage() {
    #expect(ResolvedAppLanguage.allCases.contains(ResolvedAppLanguage.effective()))
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

  // MARK: - Store

  // Prowl keeps no copy of the choice. The per-app `AppleLanguages` default is the only
  // source, and macOS writes the same key from System Settings.
  @Test func absentKeyMeansFollowSystem() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = AppLanguageStore(defaults: defaults, domainName: suite)

    #expect(store.appleLanguages == nil)
    #expect(store.language == .system)
  }

  @Test func explicitChoiceWritesOneLanguageAndSystemRemovesTheKey() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = AppLanguageStore(defaults: defaults, domainName: suite)

    store.setLanguage(.zhHans)
    #expect(store.appleLanguages == ["zh-Hans"])
    #expect(store.language == .zhHans)

    store.setLanguage(.english)
    #expect(store.appleLanguages == ["en"])
    #expect(store.language == .english)

    store.setLanguage(.system)
    #expect(store.appleLanguages == nil)
    #expect(store.language == .system)
  }

  @Test func choiceMadeInSystemSettingsIsReadBack() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = AppLanguageStore(defaults: defaults, domainName: suite)

    // System Settings writes regional identifiers and a fallback list.
    defaults.set(["zh-Hans-CN", "en-CN"], forKey: AppLanguageStore.appleLanguagesKey)
    #expect(store.language == .zhHans)

    defaults.set(["en-GB"], forKey: AppLanguageStore.appleLanguagesKey)
    #expect(store.language == .english)
  }

  @Test func languageWithoutLocalizationReadsAsEnglish() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = AppLanguageStore(defaults: defaults, domainName: suite)

    // The picker shows the language the app displays, and that is the English fallback.
    defaults.set(["ja-JP"], forKey: AppLanguageStore.appleLanguagesKey)
    #expect(store.language == .english)

    defaults.set(["zh-Hant-TW"], forKey: AppLanguageStore.appleLanguagesKey)
    #expect(store.language == .english)
  }

  @Test func followSystemRemovesAValueThatSystemSettingsWrote() {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = AppLanguageStore(defaults: defaults, domainName: suite)
    defaults.set(["zh-Hans-CN"], forKey: AppLanguageStore.appleLanguagesKey)

    store.setLanguage(.system)
    #expect(store.appleLanguages == nil)
  }

  // A shortcut title is a run-time key: the compiler cannot extract it, so
  // `make audit-localization` does not see a missing entry.
  @Test func everyShortcutTitleHasSimplifiedChineseEntry() throws {
    let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
    let bundle = try #require(Bundle(path: path))
    let sentinel = "\u{1}"
    let missing = AppShortcuts.bindings.map(\.title).filter {
      bundle.localizedString(forKey: $0, value: sentinel, table: nil) == sentinel
    }
    #expect(missing.isEmpty, "Add zh-Hans entries with extraction state manual: \(missing)")
  }

  // "Done" and "Blocked" have other meanings elsewhere (a button, a pull request
  // that cannot merge), so the agent states use their own keys.
  @Test func agentStateLabelsHaveTheirOwnCatalogEntries() throws {
    #expect(AgentDisplayState.working.label == "Working")
    #expect(AgentDisplayState.blocked.label == "Blocked")
    #expect(AgentDisplayState.done.label == "Done")
    #expect(AgentDisplayState.idle.label == "Idle")
    #expect(try chinese("agentState.working") == "工作中")
    #expect(try chinese("agentState.blocked") == "需处理")
    #expect(try chinese("agentState.done") == "已完成")
    #expect(try chinese("agentState.idle") == "空闲")
  }

  private func chinese(_ key: String) throws -> String {
    let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
    let bundle = try #require(Bundle(path: path))
    return bundle.localizedString(forKey: key, value: nil, table: nil)
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
