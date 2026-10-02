import Foundation
import Testing

@testable import supacode

struct AskAgentHelpPromptTests {
  @Test func languageKeyMapsCommonLocales() {
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "en_US")) == .english)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "ja_JP")) == .japanese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "fr_FR")) == .english)
  }

  @Test func chineseDisambiguatesByScriptThenRegion() {
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh_CN")) == .simplifiedChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh_TW")) == .traditionalChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh_HK")) == .traditionalChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh-Hant")) == .traditionalChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh-Hans")) == .simplifiedChinese)
  }

  // Script wins over region: e.g. a Simplified-Chinese user living in Japan
  // reports `zh-Hans-JP` — region JP must not flip it to English/Traditional.
  @Test func chineseScriptWinsOverNonChineseRegion() {
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh-Hans-JP")) == .simplifiedChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh-Hant-JP")) == .traditionalChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh-Hans-US")) == .simplifiedChinese)
  }

  @Test func managedAppAndGlobalSystemLanguagesRemainIndependent() {
    let combinations = [
      (
        managedAppLanguage: "zh-Hans", preferredLanguages: ["zh-Hans", "en"],
        globalLanguages: ["zh-Hans", "en"], appSentinel: "介绍 Prowl",
        promptSentinel: "Prowl 自带的文档"
      ),
      (
        managedAppLanguage: "zh-Hans", preferredLanguages: ["zh-Hans", "en"],
        globalLanguages: ["en", "zh-Hans"], appSentinel: "介绍 Prowl",
        promptSentinel: "bundled documentation"
      ),
      (
        managedAppLanguage: "en", preferredLanguages: ["en", "zh-Hans"],
        globalLanguages: ["zh-Hans", "en"], appSentinel: "about Prowl",
        promptSentinel: "Prowl 自带的文档"
      ),
      (
        managedAppLanguage: "en", preferredLanguages: ["en", "zh-Hans"],
        globalLanguages: ["en", "zh-Hans"], appSentinel: "about Prowl",
        promptSentinel: "bundled documentation"
      ),
    ]

    for combination in combinations {
      let systemLocale = AskAgentHelpPrompt.systemPreferredLocale(
        preferredLanguages: combination.preferredLanguages,
        argumentLanguages: nil,
        appLanguages: [combination.managedAppLanguage],
        globalLanguages: combination.globalLanguages
      )
      let strings = AskAgentHelpPrompt.strings(
        docsDirectoryPath: "/tmp/docs",
        appLocale: Locale(identifier: combination.managedAppLanguage),
        systemLocale: systemLocale
      )

      #expect(strings.title.contains(combination.appSentinel))
      #expect(strings.prompt.contains(combination.promptSentinel))
    }
  }

  @Test func argumentLanguageOverrideRecoversIndependentGlobalPreference() {
    let locale = AskAgentHelpPrompt.systemPreferredLocale(
      preferredLanguages: ["zh-Hans", "en"],
      argumentLanguages: ["zh-Hans"],
      appLanguages: nil,
      globalLanguages: ["en", "zh-Hans"]
    )

    #expect(AskAgentHelpPrompt.languageKey(for: locale) == .english)
  }

  @Test func processPreferenceIsUsedWithoutAnOverride() {
    let locale = AskAgentHelpPrompt.systemPreferredLocale(
      preferredLanguages: ["ja", "en"],
      argumentLanguages: nil,
      appLanguages: nil,
      globalLanguages: ["zh-Hans", "en"]
    )

    #expect(AskAgentHelpPrompt.languageKey(for: locale) == .japanese)
  }

  @Test func everySupportedLocaleRoutesToItsPromptTemplate() {
    let docs = "/Applications/Prowl.app/Contents/Resources/docs"
    let routes = [
      (identifier: "en", sentinel: "bundled documentation"),
      (identifier: "zh-Hans", sentinel: "Prowl 自带的文档"),
      (identifier: "zh-Hant", sentinel: "Prowl 內建的文件"),
      (identifier: "ja", sentinel: "同梱されているドキュメント"),
    ]

    for route in routes {
      let strings = AskAgentHelpPrompt.strings(
        docsDirectoryPath: docs,
        appLocale: Locale(identifier: "en"),
        systemLocale: Locale(identifier: route.identifier)
      )
      #expect(strings.prompt.contains(route.sentinel))
    }
  }

  @Test func docPathTrailingSlashIsNormalized() {
    let strings = AskAgentHelpPrompt.strings(
      docsDirectoryPath: "/Applications/Prowl.app/Contents/Resources/docs/",
      appLocale: Locale(identifier: "en_US"),
      systemLocale: Locale(identifier: "en_US")
    )
    #expect(strings.prompt.contains("/Applications/Prowl.app/Contents/Resources/docs/README.md"))
    #expect(strings.prompt.contains("/Applications/Prowl.app/Contents/Resources/docs/overview.md"))
    #expect(!strings.prompt.contains("docs//README.md"))
  }

  @Test func promptEmbedsResolvedDocPaths() {
    let docs = "/Applications/Prowl.app/Contents/Resources/docs"
    let strings = AskAgentHelpPrompt.strings(
      docsDirectoryPath: docs,
      appLocale: Locale(identifier: "en_US"),
      systemLocale: Locale(identifier: "en_US")
    )
    #expect(strings.prompt.contains("\(docs)/README.md"))
    #expect(strings.prompt.contains("\(docs)/overview.md"))
  }

  @Test func englishAppKeepsEnglishChromeForChineseSystemPrompt() {
    let docs = "/tmp/docs"
    let english = AskAgentHelpPrompt.strings(
      docsDirectoryPath: docs,
      appLocale: Locale(identifier: "en_US"),
      systemLocale: Locale(identifier: "en_US")
    )
    let chineseSystem = AskAgentHelpPrompt.strings(
      docsDirectoryPath: docs,
      appLocale: Locale(identifier: "en_US"),
      systemLocale: Locale(identifier: "zh_CN")
    )

    #expect(chineseSystem.title == english.title)
    #expect(chineseSystem.explanation == english.explanation)
    #expect(chineseSystem.copyButtonTitle == english.copyButtonTitle)
    #expect(chineseSystem.copiedButtonTitle == english.copiedButtonTitle)
    #expect(chineseSystem.doneButtonTitle == english.doneButtonTitle)
    #expect(chineseSystem.prompt != english.prompt)
  }

  @Test func chineseAppKeepsChineseChromeForEnglishSystemPrompt() {
    let docs = "/tmp/docs"
    let english = AskAgentHelpPrompt.strings(
      docsDirectoryPath: docs,
      appLocale: Locale(identifier: "en_US"),
      systemLocale: Locale(identifier: "en_US")
    )
    let chineseApp = AskAgentHelpPrompt.strings(
      docsDirectoryPath: docs,
      appLocale: Locale(identifier: "zh_CN"),
      systemLocale: Locale(identifier: "en_US")
    )

    #expect(chineseApp.title != english.title)
    #expect(chineseApp.explanation != english.explanation)
    #expect(chineseApp.copyButtonTitle != english.copyButtonTitle)
    #expect(chineseApp.copiedButtonTitle != english.copiedButtonTitle)
    #expect(chineseApp.doneButtonTitle != english.doneButtonTitle)
    #expect(chineseApp.prompt == english.prompt)
  }
}
