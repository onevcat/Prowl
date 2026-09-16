import Foundation
import Testing

@testable import supacode

struct WorkflowAuthoringPromptTests {
  private let skill = "/Applications/Prowl.app/Contents/Resources/skills/prowl-workflow/SKILL.md"
  private let manual = "/Applications/Prowl.app/Contents/Resources/docs/components/workflows.md"
  private let directory = "/Users/me/.prowl/workflows/"

  @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja", "fr"])
  func everyLanguageEmbedsTheSkillManualAndDirectory(identifier: String) {
    let strings = WorkflowAuthoringPrompt.strings(
      skillPath: skill,
      manualPath: manual,
      workflowsDirectory: directory,
      appLocale: Locale(identifier: "en"),
      systemLocale: Locale(identifier: identifier))

    #expect(strings.prompt.contains(skill))
    #expect(strings.prompt.contains(manual))
    #expect(strings.prompt.contains(directory))
    #expect(strings.prompt.contains("prowl workflow validate <name>.pwlworkflow"))
    #expect(strings.prompt.contains("workflow.yaml"))
    #expect(!strings.title.isEmpty)
    #expect(!strings.explanation.isEmpty)
  }

  @Test func everySupportedLocaleRoutesToItsPromptTemplate() {
    let routes = [
      (identifier: "en", sentinel: "Write a Prowl Agent Workflow"),
      (identifier: "zh-Hans", sentinel: "编写一个 Prowl Agent Workflow"),
      (identifier: "zh-Hant", sentinel: "撰寫一個 Prowl Agent Workflow"),
      (identifier: "ja", sentinel: "Agent Workflow を書いてください"),
    ]

    for route in routes {
      let strings = WorkflowAuthoringPrompt.strings(
        skillPath: skill,
        manualPath: manual,
        workflowsDirectory: directory,
        appLocale: Locale(identifier: "en"),
        systemLocale: Locale(identifier: route.identifier)
      )
      #expect(strings.prompt.contains(route.sentinel))
    }
  }

  @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja"])
  func draftIsIncludedAsAnEditableStartingPoint(identifier: String) {
    let draft = WorkflowStarterTemplate.Request(
      name: "Review #2", id: "review-2", icon: "magnifyingglass", kind: .singleAgent)
    let strings = WorkflowAuthoringPrompt.strings(
      skillPath: skill, manualPath: manual, workflowsDirectory: directory,
      draft: draft, appLocale: Locale(identifier: "en"), systemLocale: Locale(identifier: identifier))
    #expect(strings.prompt.contains(WorkflowStarterTemplate.yaml(draft)))
  }

  @Test func unsupportedLocalesFallBackToEnglish() {
    let french = WorkflowAuthoringPrompt.strings(
      skillPath: skill,
      manualPath: manual,
      workflowsDirectory: directory,
      appLocale: Locale(identifier: "en"),
      systemLocale: Locale(identifier: "fr"))
    let english = WorkflowAuthoringPrompt.strings(
      skillPath: skill,
      manualPath: manual,
      workflowsDirectory: directory,
      appLocale: Locale(identifier: "en"),
      systemLocale: Locale(identifier: "en"))
    #expect(french == english)

  }
  @Test func appAndSystemLocalesRemainIndependent() {
    let englishAppChineseSystem = WorkflowAuthoringPrompt.strings(
      skillPath: skill,
      manualPath: manual,
      workflowsDirectory: directory,
      appLocale: Locale(identifier: "en"),
      systemLocale: Locale(identifier: "zh-Hans"))
    let chineseAppEnglishSystem = WorkflowAuthoringPrompt.strings(
      skillPath: skill,
      manualPath: manual,
      workflowsDirectory: directory,
      appLocale: Locale(identifier: "zh-Hans"),
      systemLocale: Locale(identifier: "en"))
    let english = WorkflowAuthoringPrompt.strings(
      skillPath: skill,
      manualPath: manual,
      workflowsDirectory: directory,
      appLocale: Locale(identifier: "en"),
      systemLocale: Locale(identifier: "en"))

    #expect(englishAppChineseSystem.title == english.title)
    #expect(englishAppChineseSystem.prompt != english.prompt)
    #expect(chineseAppEnglishSystem.title != english.title)
    #expect(chineseAppEnglishSystem.prompt == english.prompt)
  }
}
