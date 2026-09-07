import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowSettingsCatalogTests {
  private static let review = """
    schema: prowl.workflow/v1
    id: %ID%
    name: Review
    description: Ask a reviewer.
    icon: magnifyingglass
    roles:
      author:
        source: current
      reviewer:
        source: launch
        agents: [codex]
        bind: %BIND%
    steps:
      - id: launch
        launch: reviewer
        prompt: "Review."
    """

  private static let broken = "schema: prowl.workflow/v1\nid: [\n"

  private static let userDirectory = URL(
    filePath: "/tmp/home/.prowl/workflows", directoryHint: .isDirectory)
  private static let codexProfile = AgentProfile(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Codex Review",
    runtime: .codex)
  private static let claudeProfile = AgentProfile(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Claude", runtime: .claude)

  private func entry(
    _ yaml: String, id: String = "review", bind: String = "ask", scope: WorkflowScope = .user,
    file: String = "review.yaml", shadowed: Bool = false
  ) -> WorkflowCatalogEntry {
    let directory =
      scope == .repo
      ? URL(filePath: "/tmp/repo/.prowl/workflows", directoryHint: .isDirectory)
      : Self.userDirectory
    let parsed = WorkflowDiscovery.parse(
      yaml.replacing("%ID%", with: id).replacing("%BIND%", with: bind),
      url: directory.appending(path: file, directoryHint: .notDirectory),
      scope: scope,
      context: WorkflowValidationContext(scope: scope))
    return WorkflowCatalogEntry(file: parsed, shadowed: shadowed)
  }

  private func scan(
    entries: [WorkflowCatalogEntry], repositories: [WorkflowSettingsRepositoryScan] = []
  ) -> WorkflowSettingsScan {
    WorkflowSettingsScan(
      bundleDirectory: nil, userDirectory: Self.userDirectory, entries: entries,
      repositories: repositories)
  }

  private func settings(
    disabled: [String] = [], profiles: [AgentProfile] = [codexProfile, claudeProfile]
  ) -> UserGlobalSettings {
    UserGlobalSettings(customCommands: [], agentProfiles: profiles, disabledWorkflowIDs: disabled)
  }

  @Test func rowsCarryEnabledStateBindAndCandidates() throws {
    let catalog = WorkflowSettingsCatalog.build(
      scan: scan(entries: [entry(Self.review)]),
      settings: settings(disabled: ["user/other"]))

    let row = try #require(catalog.user.first)
    #expect(catalog.bundle.isEmpty)
    #expect(catalog.repositories.isEmpty)
    #expect(row.settingsKey == "user/review")
    #expect(row.isEnabled)
    #expect(row.isValid)
    #expect(row.name == "Review")
    #expect(row.description == "Ask a reviewer.")
    #expect(row.icon == "magnifyingglass")
    #expect(row.declaredBind == .ask)
    #expect(row.bindModeOverride == nil)
    #expect(row.shadowNote == nil)
    #expect(row.status == .ready)

    let role = try #require(row.launchRoles.first)
    #expect(role.name == "reviewer")
    #expect(role.rememberedProfileID == nil)
    #expect(role.memoryKey.scope == "user")
    #expect(role.candidates.map(\.name) == ["Codex Review", "Claude"])
    #expect(role.candidates[0].unavailableReason == nil)
    #expect(role.candidates[1].unavailableReason == "This role needs codex.")
  }

  @Test func disabledKeyOverrideAndMemoryAreReflected() throws {
    var stored = settings(disabled: ["user/review"])
    stored.setWorkflowBindMode(.auto, for: "user/review")
    let parsed = entry(Self.review)
    let role = try #require(parsed.file.definition?.roles.first { $0.name == "reviewer" })
    let key = WorkflowBindingResolver.memoryKey(scope: .user, workflowID: "review", role: role)
    stored.remember(workflowBinding: key, profileID: Self.codexProfile.id)

    let row = try #require(
      WorkflowSettingsCatalog.build(scan: scan(entries: [parsed]), settings: stored).user.first)
    #expect(!row.isEnabled)
    #expect(row.bindModeOverride == .auto)
    #expect(row.launchRoles.first?.rememberedProfileID == Self.codexProfile.id)
  }

  @Test func aDisabledRememberedProfileStaysListedWithItsReason() throws {
    var disabledCodex = Self.codexProfile
    disabledCodex.isEnabled = false
    var stored = settings(profiles: [disabledCodex, Self.claudeProfile])
    let parsed = entry(Self.review)
    let role = try #require(parsed.file.definition?.roles.first { $0.name == "reviewer" })
    stored.remember(
      workflowBinding: WorkflowBindingResolver.memoryKey(
        scope: .user, workflowID: "review", role: role),
      profileID: disabledCodex.id)

    let row = try #require(
      WorkflowSettingsCatalog.build(scan: scan(entries: [parsed]), settings: stored).user.first)
    let launchRole = try #require(row.launchRoles.first)
    #expect(launchRole.rememberedProfileID == disabledCodex.id)
    // Settings order (the profiles' recommendation order): the enabled Claude with its own
    // rejection, the disabled remembered Codex with its reason — never other disabled profiles.
    #expect(launchRole.candidates.map(\.name) == ["Codex Review", "Claude"])
    #expect(launchRole.candidates[0].unavailableReason == "Disabled in Settings.")
    #expect(launchRole.candidates[1].unavailableReason == "This role needs codex.")
  }

  @Test func repositoryRowsUseTheRepoScopeAndOnlyRepositoriesWithFilesAreListed() throws {
    let userEntry = entry(Self.review)
    let repoEntry = entry(Self.review, scope: .repo, file: "repo-review.yaml")
    let shadowedUser = WorkflowCatalogEntry(file: userEntry.file, shadowed: true)
    let repositories = [
      WorkflowSettingsRepositoryScan(
        repositoryID: "repo-a", name: "Alpha", rootPath: "/tmp/repo/",
        directory: URL(filePath: "/tmp/repo/.prowl/workflows", directoryHint: .isDirectory),
        entries: [shadowedUser, repoEntry]),
      WorkflowSettingsRepositoryScan(
        repositoryID: "repo-b", name: "Beta", rootPath: "/tmp/other/",
        directory: URL(filePath: "/tmp/other/.prowl/workflows", directoryHint: .isDirectory),
        entries: [userEntry]),
    ]

    let catalog = WorkflowSettingsCatalog.build(
      scan: scan(entries: [userEntry], repositories: repositories), settings: settings())

    #expect(catalog.repositories.map(\.name) == ["Alpha"])
    let repoRow = try #require(catalog.repositories.first?.rows.first)
    #expect(repoRow.settingsKey == "repo:/tmp/repo/review")
    #expect(repoRow.launchRoles.first?.memoryKey.scope == "repo:/tmp/repo/")
    #expect(repoRow.shadowNote == nil)
    #expect(repoRow.precedenceNote == "Overrides your personal workflow in this repository.")
    #expect(catalog.user.first?.shadowNote == "Overridden in Alpha")
  }

  @Test func aLaterFileWithTheSameIdIsMarkedAsOverridden() throws {
    let winner = entry(Self.review, file: "a.yaml")
    let loser = entry(Self.review, file: "b.yaml", shadowed: true)

    let catalog = WorkflowSettingsCatalog.build(
      scan: scan(entries: [winner, loser]), settings: settings())

    #expect(catalog.user.map(\.shadowNote) == [nil, "Overridden by a.yaml"])
    #expect(
      catalog.user.map(\.id) == [
        winner.file.url.path(percentEncoded: false), loser.file.url.path(percentEncoded: false),
      ])
  }

  @Test func anUnparsedFileHasNoKeyAndNoRoles() throws {
    let catalog = WorkflowSettingsCatalog.build(
      scan: scan(entries: [entry(Self.broken, file: "broken.yaml")]), settings: settings())

    let row = try #require(catalog.user.first)
    #expect(row.workflowID == nil)
    #expect(row.settingsKey == nil)
    #expect(!row.isEnabled)
    #expect(!row.isValid)
    #expect(row.name == "broken.yaml")
    #expect(row.launchRoles.isEmpty)
    #expect(row.declaredBind == nil)
    #expect(row.errorCount >= 1)
  }

  @Test func listStatusPrioritizesRecoveryAndEffectiveAvailability() throws {
    let warning = Self.review.replacing(
      "    prompt: \"Review.\"",
      with: "    prompt: \"Review.\"\n    expect: { delivery: report, timeout: 3h }")
    let ready = try #require(
      WorkflowSettingsCatalog.build(
        scan: scan(entries: [entry(Self.review)]),
        settings: settings()
      ).user.first)
    let disabled = try #require(
      WorkflowSettingsCatalog.build(
        scan: scan(entries: [entry(Self.review)]),
        settings: settings(disabled: ["user/review"])
      ).user.first)
    let warned = try #require(
      WorkflowSettingsCatalog.build(
        scan: scan(entries: [entry(warning)]),
        settings: settings()
      ).user.first)
    let invalid = try #require(
      WorkflowSettingsCatalog.build(
        scan: scan(entries: [entry(Self.broken, file: "broken.yaml")]),
        settings: settings()
      ).user.first)
    let superseded = try #require(
      WorkflowSettingsCatalog.build(
        scan: scan(entries: [
          entry(Self.review, file: "winner.yaml"),
          entry(Self.review, file: "loser.yaml", shadowed: true),
        ]),
        settings: settings()
      ).user.last)

    #expect(ready.status == .ready)
    #expect(disabled.status == .disabled)
    #expect(warned.status == .readyWithWarnings(warned.warningCount))
    #expect(invalid.status == .invalid(errors: invalid.errorCount))
    #expect(superseded.status == .superseded)
  }

  @Test func rolesDescribeEverySourceAndOnlyLaunchRolesCarryProfiles() throws {
    let yaml = Self.review.replacing(
      "  reviewer:\n    source: launch",
      with: "  partner:\n    source: pick\n  reviewer:\n    source: launch")
    let row = try #require(
      WorkflowSettingsCatalog.build(
        scan: scan(entries: [entry(yaml)]),
        settings: settings()
      ).user.first)

    #expect(row.roles.map(\.name) == ["author", "partner", "reviewer"])
    #expect(
      row.roles.map(\.behaviorDescription) == [
        "Uses the pane that starts this workflow.",
        "Choose an existing agent when starting.",
        "Prowl launches a new agent in a split on the right.",
      ])
    #expect(row.roles.compactMap(\.launch).count == 1)
    #expect(row.launchRoles.map(\.name) == ["reviewer"])
  }

  @Test func mixedDeclaredBindsReportNoUniformBind() throws {
    let yaml = Self.review.replacing(
      "    bind: %BIND%\n",
      with: "    bind: %BIND%\n  second:\n    source: launch\n    bind: auto\n")
    let catalog = WorkflowSettingsCatalog.build(
      scan: scan(entries: [entry(yaml)]), settings: settings())
    #expect(catalog.user.first?.declaredBind == nil)
    #expect(catalog.user.first?.launchRoles.map(\.name) == ["reviewer", "second"])
  }
}
