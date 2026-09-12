import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowStarterTemplateTests {
  @Test(arguments: WorkflowStarterTemplate.Kind.allCases)
  func userTextRoundTripsWithoutChangingYAML(kind: WorkflowStarterTemplate.Kind) throws {
    let names = ["Review: today's changes", "Review #2", "true", "2026", "日本語", "A \"quote\" \\ path", "First\nSecond"]
    for name in names {
      let request = WorkflowStarterTemplate.Request(name: name, id: "123", icon: "true", kind: kind)
      let parsed = WorkflowDocumentParser.parse(WorkflowStarterTemplate.yaml(request))
      let definition = try #require(parsed.definition, "\(name): \(parsed.diagnostics)")
      #expect(parsed.diagnostics.isEmpty)
      #expect(definition.name == name)
      #expect(definition.id == "123")
      #expect(definition.icon == "true")
    }
  }

  @Test(arguments: WorkflowStarterTemplate.Kind.allCases)
  func starterValidatesAsAUserWorkflow(kind: WorkflowStarterTemplate.Kind) throws {
    let request = WorkflowStarterTemplate.Request(name: "Daily Check", id: "daily-check", icon: "calendar", kind: kind)
    let yaml = WorkflowStarterTemplate.yaml(request)
    let parsed = WorkflowDocumentParser.parse(yaml)
    let definition = try #require(parsed.definition)
    #expect(parsed.diagnostics.isEmpty, "\(parsed.diagnostics)")
    #expect(definition.id == "daily-check")
    #expect(definition.name == "Daily Check")
    #expect(definition.icon == "calendar")
    #expect(yaml.contains(WorkflowStarterTemplate.Documentation.standard.manualPath))
    #expect(yaml.contains(WorkflowStarterTemplate.Documentation.standard.skillPath))

    let diagnostics = WorkflowValidator.validate(definition, context: WorkflowValidationContext(scope: .user))
    #expect(diagnostics.filter { $0.severity == .error }.isEmpty, "\(diagnostics)")
    switch kind {
    case .singleAgent:
      #expect(definition.roles.map(\.source) == [.current])
      #expect(definition.steps.map(\.id) == ["ask", "done"])
      #expect(definition.inputs.map(\.name) == ["style"])
    case .multiAgent:
      #expect(definition.roles.map(\.source) == [.current, .launch])
      #expect(definition.steps.map(\.id) == ["pick", "counter", "done"])
      #expect(definition.steps[0].action.expect?.verdicts == ["rock", "paper", "scissors"])
    }
  }

  @Test func omittedIconStaysACommentAndCustomDocsPathsAreUsed() throws {
    var request = WorkflowStarterTemplate.Request(name: "Ping", id: "ping", icon: nil, kind: .singleAgent)
    request.documentation = .init(manualPath: "/tmp/docs/workflows.md", skillPath: "/tmp/skills/SKILL.md")
    let yaml = WorkflowStarterTemplate.yaml(request)
    #expect(yaml.contains("# icon: calendar"))
    #expect(yaml.contains("# Manual: /tmp/docs/workflows.md"))
    #expect(yaml.contains("# Skill:  /tmp/skills/SKILL.md"))
    let definition = try #require(WorkflowDocumentParser.parse(yaml).definition)
    #expect(definition.icon == nil)
  }

  @Test func suggestedIDsAreSchemaSlugs() {
    #expect(WorkflowStarterTemplate.suggestedID(for: "Daily Check") == "daily-check")
    #expect(WorkflowStarterTemplate.suggestedID(for: "  Rock, Paper & Scissors!  ") == "rock-paper-scissors")
    #expect(WorkflowStarterTemplate.suggestedID(for: "Review #2") == "review-2")
    #expect(WorkflowStarterTemplate.suggestedID(for: "日本語") == "")
    #expect(WorkflowSchema.isWorkflowID(WorkflowStarterTemplate.suggestedID(for: "Daily Check")))
  }

  @Test func writeUsesTheIDAsFolderNameAndNeverOverwrites() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "prowl-starter-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = WorkflowStarterTemplate.Request(name: "Ping", id: "ping", icon: nil, kind: .multiAgent)

    let url = try WorkflowStarterTemplate.write(request, in: directory)
    #expect(url.lastPathComponent == "ping.pwlworkflow")
    let written = try String(contentsOf: url.appending(path: "workflow.yaml"), encoding: .utf8)
    #expect(WorkflowDocumentParser.parse(written).definition?.id == "ping")
    #expect(throws: (any Error).self) { try WorkflowStarterTemplate.write(request, in: directory) }
    #expect(WorkflowDocumentParser.parse(written).definition?.id == "ping")
  }
}
