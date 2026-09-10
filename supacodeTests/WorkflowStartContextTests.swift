import Foundation
import ProwlCLIShared
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
        prompt: "Write about {{ inputs.focus }}."
        expect: { delivery: brief }
      - id: launch
        launch: reviewer
        prompt: "Read {{ deliveries.brief.path }}."
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
        key: "user/\(definition.id)",
        scope: .user,
        fileURL: URL(filePath: "/tmp/\(definition.id).yaml"),
        workflowID: definition.id,
        name: definition.name,
        workflowDescription: nil,
        icon: definition.icon,
        validationFailure: validationFailure),
      definition: definition,
      worktreeID: "/tmp/wt/", worktreeName: "main",
      source: source,
      launchRoles: launchRoles,
      pickRoles: pickRoles,
      cliInstalled: cliInstalled,
      bindModeOverride: nil,
      cliServiceFailure: cliServiceFailure)
  }

  private func launchRole(bind: WorkflowBindMode = .auto, resolved: UUID? = profileID)
    -> WorkflowStartLaunchRole
  {
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

  @Test func catalogItemCarriesTheWorkflowIcon() throws {
    let url = URL(filePath: "/tmp/icon.yaml")
    let file = WorkflowDiscovery.parse(
      Self.autoFlow.replacing("name: Auto Flow", with: "name: Auto Flow\nicon: bolt"),
      url: url,
      scope: .user,
      context: WorkflowValidationContext(scope: .user))

    let item = try #require(
      WorkflowStartCatalogItem.make(
        entry: WorkflowCatalogEntry(file: file, shadowed: false),
        disabledWorkflowIDs: [],
        repositoryRootPath: nil))

    #expect(item.scope == .user)
    #expect(item.fileURL == url)
    #expect(item.icon == "bolt")
  }

  @Test func startsImmediatelyWhenNothingIsUndecided() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()])
    #expect(context.canStartImmediately)
  }

  @Test func askBindAlwaysPresentsTheSheet() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole(bind: .ask)])
    #expect(!context.canStartImmediately)
  }

  @Test func unresolvedAutoRolePresentsTheSheet() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole(resolved: nil)])
    #expect(!context.canStartImmediately)
  }

  @Test func pickRolesAreAlwaysAnExplicitChoice() throws {
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()],
      pickRoles: [WorkflowStartPickRole(name: "partner", candidates: [Self.agentPane])])
    #expect(!context.canStartImmediately)
  }

  @Test func defaultlessInputPresentsTheSheet() throws {
    let yaml = Self.autoFlow.replacing(
      "focus: { type: string, default: \"\" }", with: "focus: { type: string }")
    let context = try context(
      yaml: yaml, source: source(preselected: Self.agentPane), launchRoles: [launchRole()])
    #expect(!context.canStartImmediately)
  }

  @Test func theBannerActionFollowsTheInstallStatus() throws {
    var context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()], cliInstalled: false)
    #expect(context.cliInstallActionTitle == "Install")
    context.cliInstallStatus = .broken(path: "/usr/local/bin/prowl", destination: "/gone")
    #expect(context.cliInstallActionTitle == "Repair")
    context.cliInstallStatus = .installedDifferentSource(
      path: "/usr/local/bin/prowl", destination: "/other")
    #expect(context.cliInstallActionTitle == "Reinstall")
    context.cliInstallStatus = .installedDifferentSource(
      path: "/usr/local/bin/prowl", destination: nil)
    #expect(context.cliInstallActionTitle == nil)
    #expect(context.cliInstallBlockerCopy.contains("Remove it"))
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
    let context = try context(
      source: source(preselected: Self.bareShellPane), launchRoles: [launchRole()])
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
    let context = try context(
      source: source(preselected: Self.agentPane), launchRoles: [launchRole()])
    #expect(context.skipOptions.map(\.stepID) == ["brief"])
  }
}
