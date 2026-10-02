import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowLineRendererTests {
  private let token = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

  // MARK: - Completion command

  @Test func launchPromptAccepts128KiB() throws {
    try WorkflowLaunchPrompt.validate(String(repeating: "x", count: 128 * 1024))
  }

  @Test func messageCommandCarriesTokenPrefixAndOneCommandPerVerdict() {
    let plain = WorkflowCompletionCommand(token: token, verdicts: nil)
    #expect(plain.messageCommands == ["PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver -"])
    #expect(plain.typedSuffix == " — finish with: PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver -")

    let verdicts = WorkflowCompletionCommand(token: token, verdicts: ["clean", "issues"])
    #expect(
      verdicts.messageCommands == [
        "PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver --verdict clean -",
        "PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver --verdict issues -",
      ])
    #expect(
      verdicts.typedSuffix
        == " — finish with: PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver --verdict clean -"
        + "  or  PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver --verdict issues -")
    #expect(
      verdicts.launchCommands == [
        "prowl workflow deliver --verdict clean -", "prowl workflow deliver --verdict issues -",
      ])
  }

  @Test func nudgeLineUsesThePrefixAndTheSameCommands() throws {
    let command = WorkflowCompletionCommand(token: token, verdicts: ["clean", "issues"])
    let line = try WorkflowTypedLine.nudge(completion: command)
    #expect(line.hasPrefix(AgentDispatchPrompt.injectedPrefix))
    #expect(
      line
        == "[Prowl] When your work for this step is fully complete, finish with: "
        + "PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver --verdict clean -"
        + "  or  PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver --verdict issues -")
  }

  @Test func protocolBlockNamesRunRoleSectionsAndEveryCommandWithoutPrefix() {
    let command = WorkflowCompletionCommand(token: token, verdicts: ["clean", "issues"])
    let block = command.protocolBlock(
      runID: "RUN-1", workflowName: "Adversarial Review", role: "reviewer", stepTitle: "Reviewer starting round 1",
      expect: WorkflowExpectation(sections: ["## Findings", "## Verdict"]))
    #expect(block.contains("Prowl workflow completion protocol v1"))
    #expect(block.contains("RUN-1"))
    #expect(block.contains("Adversarial Review"))
    #expect(block.contains("\"reviewer\""))
    #expect(block.contains("## Findings, ## Verdict"))
    #expect(block.contains("\nprowl workflow deliver --verdict clean -\n"))
    #expect(block.contains("\nprowl workflow deliver --verdict issues -\n"))
    #expect(!block.contains("PROWL_WORKFLOW_TOKEN"))
    #expect(block.contains("dispatch-complete"))
  }

  @Test func completionTrailerAndDeliveryRequiredMessageListTheMessageCommands() {
    let command = WorkflowCompletionCommand(token: token, verdicts: nil)
    let trailer = command.completionTrailer()
    #expect(trailer.contains("PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver -"))
    let message = command.deliveryRequiredMessage(runID: "RUN-1", stepID: "brief")
    #expect(message.contains("RUN-1"))
    #expect(message.contains("brief"))
    #expect(message.contains("PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver -"))
  }

  // MARK: - Typed lines

  @Test func textLineIsPrefixedAndSuffixed() throws {
    let command = WorkflowCompletionCommand(token: token, verdicts: nil)
    #expect(
      try WorkflowTypedLine.text("Findings: /r/deliveries/findings.md", completion: nil)
        == "[Prowl] Findings: /r/deliveries/findings.md")
    #expect(
      try WorkflowTypedLine.text("Fix each item.", completion: command)
        == "[Prowl] Fix each item. — finish with: PROWL_WORKFLOW_TOKEN=\(token) prowl workflow deliver -")
  }

  @Test func promptTransportUsesScopedReadForLongOrUnsafeLines() throws {
    let root = URL(filePath: "/tmp/workflow-run")
    for body in ["First\nSecond", "Tab\ttext", "Escape\u{1B}", String(repeating: "x", count: 4096)] {
      let grant = WorkflowTaskContent.make(
        text: body, task: (UUID(), 1), runDirectory: root, knownPaths: [], skill: nil)
      #expect(try WorkflowTypedLine.prompt(grant, completion: nil) == "[Prowl] " + grant.guidance)
    }
    let grant = WorkflowTaskContent.make(
      text: "Review.", task: (UUID(), 1), runDirectory: root, knownPaths: [], skill: nil)
    #expect(try WorkflowTypedLine.prompt(grant, completion: nil) == "[Prowl] Review.")
  }

  @Test func renderedTextBoundaryRejectsTerminatorsAndControls() {
    for bad in ["a\nb", "a\rb", "a\u{2028}b", "a\u{2029}b", "a\tb", "a\u{1B}[0m", "a\u{85}b", "a\u{9F}b"] {
      #expect(throws: WorkflowRenderedTextError.self) { try WorkflowRenderedText.validateLine(bad) }
    }
    #expect(throws: Never.self) { try WorkflowRenderedText.validateLine("plain ascii — with dash and emoji 🐱") }
  }

  @Test func typedLineWithInjectedTerminatorFailsWithoutPartialOutput() {
    #expect(throws: WorkflowRenderedTextError.self) {
      try WorkflowTypedLine.text("first\nsecond", completion: nil)
    }
  }

  // MARK: - Launch prompt

  @Test func launchPromptRejectsNULAndOversize() {
    #expect(throws: WorkflowLaunchPromptError.containsNUL) { try WorkflowLaunchPrompt.validate("a\0b") }
    let big = String(repeating: "x", count: WorkflowLaunchPrompt.maximumBytes + 1)
    #expect(throws: WorkflowLaunchPromptError.tooLarge(bytes: WorkflowLaunchPrompt.maximumBytes + 1)) {
      try WorkflowLaunchPrompt.validate(big)
    }
    #expect(throws: Never.self) { try WorkflowLaunchPrompt.validate("multi\nline\nprompt") }
  }

  @Test func launchPromptAppendsProtocolBlockAfterASeparator() {
    let command = WorkflowCompletionCommand(token: token, verdicts: nil)
    let block = command.protocolBlock(
      runID: "R", workflowName: "W", role: "reviewer", stepTitle: nil, expect: WorkflowExpectation())
    let prompt = WorkflowLaunchPrompt.render(userPrompt: "Review it.", protocolBlock: block)
    #expect(prompt.hasPrefix("Review it.\n\n---\n"))
    #expect(prompt.hasSuffix(block))
    #expect(WorkflowLaunchPrompt.render(userPrompt: "Plain", protocolBlock: nil) == "Plain")
  }
}
