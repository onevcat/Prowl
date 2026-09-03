import Foundation
import Testing

@testable import supacode

struct WorkflowStartContextTests {
  static let autoFlow = """
    schema: prowl.workflow/v1
    id: auto-flow
    name: Auto Flow
    inputs:
      focus: { type: string, default: "" }
    roles:
      author:
        source: current
      reviewer:
        source: launch
        bind: auto
    steps:
      - id: brief
        message: author
        text: "Write about {{ inputs.focus }}."
        expect: { output: brief }
      - id: launch
        launch: reviewer
        prompt: "Read {{ outputs.brief.path }}."
    """

  static let worktreeOnly = """
    schema: prowl.workflow/v1
    id: worktree-only
    name: Worktree Only
    roles:
      runner:
        source: launch
        bind: auto
    steps:
      - id: launch
        launch: runner
        prompt: "Do the thing."
    """

  private static let agentPane = WorkflowStartPaneCandidate(
    surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    handle: "p1", agentToken: "claude", agentDisplayName: "Claude Code", paneTitle: "claude")
  private static let bareShellPane = WorkflowStartPaneCandidate(
    surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    handle: "p2", agentToken: nil, agentDisplayName: nil, paneTitle: "zsh")
  private static let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!

  private func definition(_ yaml: String) throws -> WorkflowDefinition {
    try #require(WorkflowDocumentParser.parse(yaml).definition)
  }

  private func context(
    yaml: String = autoFlow,
    source: WorkflowStartSource?,
    launchRoles: [WorkflowStartLaunchRole],
    pickRoles: [WorkflowStartPickRole] = [],
    cliInstalled: Bool = true,
    cliServiceFailure: String? = nil,
    validationFailure: String? = nil
  ) throws -> WorkflowStartContext {
    let definition = try definition(yaml)
    return WorkflowStartContext(
      item: WorkflowStartCatalogItem(
        key: "user/\(definition.id)", workflowID: definition.id, name: definition.name,
        workflowDescription: nil, validationFailure: validationFailure),
      definition: definition,
      worktreeID: "/tmp/wt/", worktreeName: "main",
      source: source,
      launchRoles: launchRoles,
      pickRoles: pickRoles,
      cliInstalled: cliInstalled,
      bindModeOverride: nil,
      cliServiceFailure: cliServiceFailure)
  }

  private func launchRole(bind: WorkflowBindMode = .auto, resolved: UUID? = profileID) -> WorkflowStartLaunchRole {
    WorkflowStartLaunchRole(
      name: "reviewer", effectiveBind: bind, resolvedProfileID: resolved,
      candidates: [], suggestion: nil, rejectedNote: nil)
  }

  private func source(preselected: WorkflowStartPaneCandidate?) -> WorkflowStartSource {
    WorkflowStartSource(
      roleName: "author",
      candidates: [Self.agentPane, Self.bareShellPane],
      preselectedSurfaceID: preselected?.surfaceID)
  }

  @Test func startsImmediatelyWhenNothingIsUndecided() throws {
    let context = try context(source: source(preselected: Self.agentPane), launchRoles: [launchRole()])
    #expect(context.canStartImmediately)
  }

  @Test func askBindAlwaysPresentsTheSheet() throws {
    let context = try context(source: source(preselected: Self.agentPane), launchRoles: [launchRole(bind: .ask)])
    #expect(!context.canStartImmediately)
  }

  @Test func unresolvedAutoRolePresentsTheSheet() throws {
    let context = try context(source: source(preselected: Self.agentPane), launchRoles: [launchRole(resolved: nil)])
    #expect(!context.canStartImmediately)
  }

  @Test func pickRolesAreAlwaysAnExplicitChoice() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()],
      pickRoles: [WorkflowStartPickRole(name: "partner", candidates: [Self.agentPane])])
    #expect(!context.canStartImmediately)
  }

  @Test func defaultlessInputPresentsTheSheet() throws {
    let yaml = Self.autoFlow.replacing("focus: { type: string, default: \"\" }", with: "focus: { type: string }")
    let context = try context(yaml: yaml, source: source(preselected: Self.agentPane), launchRoles: [launchRole()])
    #expect(!context.canStartImmediately)
  }

  @Test func unreachableSocketPresentsTheSheet() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()],
      cliServiceFailure: "Another Prowl instance owns the socket.")
    #expect(!context.canStartImmediately)
  }

  @Test func missingCLIPresentsTheSheet() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()], cliInstalled: false)
    #expect(!context.canStartImmediately)
  }

  @Test func bareShellSourceNeedsTheSheetWhenAMessageDelivers() throws {
    let context = try context(source: source(preselected: Self.bareShellPane), launchRoles: [launchRole()])
    #expect(!context.canStartImmediately)
  }

  @Test func missingPreselectionPresentsTheSheet() throws {
    let context = try context(source: source(preselected: nil), launchRoles: [launchRole()])
    #expect(!context.canStartImmediately)
  }

  @Test func workflowWithoutACurrentRoleRunsAgainstTheWorktree() throws {
    let context = try context(yaml: Self.worktreeOnly, source: nil, launchRoles: [launchRole()])
    #expect(context.canStartImmediately)
  }

  @Test func invalidWorkflowNeverStartsImmediately() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()],
      validationFailure: "2 validation errors")
    #expect(!context.canStartImmediately)
  }

  @Test func skipOptionsListEveryExpectCarryingStep() throws {
    let context = try context(source: source(preselected: Self.agentPane), launchRoles: [launchRole()])
    #expect(context.skipOptions.map(\.stepID) == ["brief"])
  }
}
