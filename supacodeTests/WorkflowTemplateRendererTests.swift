import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowTemplateRendererTests {
  private func makeContext() -> WorkflowTemplateContext {
    WorkflowTemplateContext(
      run: WorkflowTemplateContext.Run(id: "RUN-1", directory: "/repo/.prowl/workflow-runs/RUN-1"),
      worktree: WorkflowTemplateContext.Worktree(path: "/repo", name: "feature", branch: "feat/x"),
      roles: [
        "author": WorkflowTemplateContext.Role(name: "Claude Code", agent: "claude", pane: "p3"),
        "reviewer": WorkflowTemplateContext.Role(name: "Pi Reviewer", agent: "pi", pane: nil),
      ],
      outputs: [
        "findings": WorkflowTemplateContext.Output(
          path: "/repo/.prowl/workflow-runs/RUN-1/outputs/findings.md", verdict: "issues"),
        "brief": WorkflowTemplateContext.Output(
          path: "/repo/.prowl/workflow-runs/RUN-1/outputs/brief.md", verdict: nil),
      ],
      skippedOutputs: ["disposition"],
      actions: ["transition": ["kickoff_prompt": "Take over.", "has_briefing": "true"]],
      inputs: ["max_rounds": "5", "focus": "the parser"],
      loop: WorkflowTemplateContext.Loop(index: 2, count: 1)
    )
  }

  @Test func rendersEveryAllowedVariable() throws {
    let context = makeContext()
    let text = """
      {{ run.id }}|{{ run.dir }}|{{ worktree.path }}|{{ worktree.name }}|{{ worktree.branch }}|\
      {{ roles.author.name }}|{{ roles.author.agent }}|{{ roles.author.pane }}|{{ roles.reviewer.name }}|\
      {{ outputs.findings.path }}|{{ outputs.findings.verdict }}|{{ actions.transition.kickoff_prompt }}|\
      {{ inputs.max_rounds }}|{{ inputs.focus }}|{{ loop.index }}|{{ loop.count }}
      """
    let rendered = try WorkflowTemplate.render(text, context: context)
    #expect(
      rendered
        == "RUN-1|/repo/.prowl/workflow-runs/RUN-1|/repo|feature|feat/x|Claude Code|claude|p3|Pi Reviewer|"
        + "/repo/.prowl/workflow-runs/RUN-1/outputs/findings.md|issues|Take over.|5|the parser|2|1")
  }

  @Test func textWithoutReferencesIsReturnedVerbatim() throws {
    #expect(try WorkflowTemplate.render("no placeholders here", context: makeContext()) == "no placeholders here")
  }

  @Test func skippedOutputIsTheSkipRuleSignal() {
    #expect(throws: WorkflowTemplateError.missingOutput(name: "disposition")) {
      try WorkflowTemplate.render("Read {{ outputs.disposition.path }}", context: makeContext())
    }
  }

  @Test func neverProducedOutputIsAlsoMissing() {
    #expect(throws: WorkflowTemplateError.missingOutput(name: "nothing")) {
      try WorkflowTemplate.render("{{ outputs.nothing.path }}", context: makeContext())
    }
  }

  @Test func verdictOfAnOutputWithoutVerdictIsUnavailable() {
    #expect(throws: WorkflowTemplateError.verdictUnavailable(output: "brief")) {
      try WorkflowTemplate.render("{{ outputs.brief.verdict }}", context: makeContext())
    }
  }

  @Test func paneOfAnUnlaunchedRoleIsUnavailable() {
    #expect(throws: WorkflowTemplateError.paneUnavailable(role: "reviewer")) {
      try WorkflowTemplate.render("{{ roles.reviewer.pane }}", context: makeContext())
    }
  }

  @Test func unknownVariablesAndMalformedPlaceholdersThrow() {
    #expect(throws: WorkflowTemplateError.unknownVariable("run.nope")) {
      try WorkflowTemplate.render("{{ run.nope }}", context: makeContext())
    }
    #expect(throws: WorkflowTemplateError.unknownVariable("inputs.other")) {
      try WorkflowTemplate.render("{{ inputs.other }}", context: makeContext())
    }
    #expect(throws: WorkflowTemplateError.unknownVariable("loop.index")) {
      var context = makeContext()
      context.loop = WorkflowTemplateContext.Loop(index: nil, count: 0)
      _ = try WorkflowTemplate.render("{{ loop.index }}", context: context)
    }
    #expect(throws: WorkflowTemplateError.malformed(.unbalanced)) {
      try WorkflowTemplate.render("{{ run.id", context: makeContext())
    }
  }

  @Test func substitutedValuesAreNotReScanned() throws {
    var context = makeContext()
    context.inputs["focus"] = "{{ run.id }}"
    #expect(try WorkflowTemplate.render("[{{ inputs.focus }}]", context: context) == "[{{ run.id }}]")
  }
}
