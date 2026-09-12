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
      skillPath: skill, manualPath: manual, workflowsDirectory: directory, locale: Locale(identifier: identifier))

    #expect(strings.prompt.contains(skill))
    #expect(strings.prompt.contains(manual))
    #expect(strings.prompt.contains(directory))
    #expect(strings.prompt.contains("prowl workflow validate <name>.pwlworkflow"))
    #expect(strings.prompt.contains("workflow.yaml"))
    #expect(!strings.title.isEmpty)
    #expect(!strings.explanation.isEmpty)
  }

  @Test(arguments: ["en", "zh-Hans", "zh-Hant", "ja"])
  func draftIsIncludedAsAnEditableStartingPoint(identifier: String) {
    let draft = WorkflowStarterTemplate.Request(
      name: "Review #2", id: "review-2", icon: "magnifyingglass", kind: .singleAgent)
    let strings = WorkflowAuthoringPrompt.strings(
      skillPath: skill, manualPath: manual, workflowsDirectory: directory,
      draft: draft, locale: Locale(identifier: identifier))
    #expect(strings.prompt.contains(WorkflowStarterTemplate.yaml(draft)))
  }

  @Test func unsupportedLocalesFallBackToEnglish() {
    let french = WorkflowAuthoringPrompt.strings(
      skillPath: skill, manualPath: manual, workflowsDirectory: directory, locale: Locale(identifier: "fr"))
    let english = WorkflowAuthoringPrompt.strings(
      skillPath: skill, manualPath: manual, workflowsDirectory: directory, locale: Locale(identifier: "en"))
    #expect(french == english)
  }
}
