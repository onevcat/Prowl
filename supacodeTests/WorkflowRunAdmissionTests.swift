// supacodeTests/WorkflowRunAdmissionTests.swift
// Preflight of `prowl workflow run` (docs-ai 063 B3): definition selection, source and binding
// legality, one run per pane, frozen plans, and the initial record.

import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowRunAdmissionTests {
  private static let review = """
    schema: prowl.workflow/v1
    id: review
    name: Review
    inputs:
      rounds: { type: integer, default: 2, min: 1, max: 5 }
    roles:
      author:
        source: current
      reviewer:
        source: launch
        agents: [codex, claude]
      partner:
        source: pick
    steps:
      - id: brief
        message: author
        prompt: "Brief {{ inputs.rounds }}"
        expect: { delivery: brief }
      - id: launch
        launch: reviewer
        prompt: "Review {{ deliveries.brief.path }}"
        expect: { delivery: findings }
      - id: ping
        message: partner
        prompt: "Findings: {{ deliveries.findings.path }}"
    """

  private static let contextOnly = """
    schema: prowl.workflow/v1
    id: context
    name: Context
    roles:
      author:
        source: current
    steps:
      - id: ctx
        action: builtin:collect-worktree-context
        with: { root: "{{ context.worktree.path }}" }
    """

  private static let worktreeOnly = """
    schema: prowl.workflow/v1
    id: launch-only
    name: Launch Only
    roles:
      worker:
        source: launch
    steps:
      - id: go
        launch: worker
        prompt: "Go"
    """

  private static let claudeID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private static let codexID = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
  private static let ampID = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

  @MainActor
  final class Fixture {
    let root: URL
    let repoRoot: URL
    let userWorkflows: URL
    let authorPane = UUID()
    let partnerPane = UUID()
    let shellPane = UUID()
    let tabID = UUID()
    var agents: [UUID: WorkflowDetectedAgent]
    var remembered: [WorkflowBindingMemoryKey: UUID] = [:]
    var busy: Set<UUID> = []
    var pendingDispatches: [UUID: String] = [:]
    var plannedProfiles: [String] = []
    var disabled: Set<String> = []
    var designated: UUID?

    init() throws {
      root =
        FileManager.default.temporaryDirectory
        .appending(
          path: "prowl-workflow-admission-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .standardizedFileURL
      repoRoot = root.appending(path: "repo", directoryHint: .isDirectory)
      userWorkflows = root.appending(path: "home/.prowl/workflows", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: userWorkflows, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: WorkflowSources.repoDirectory(root: repoRoot), withIntermediateDirectories: true)
      agents = [
        authorPane: WorkflowDetectedAgent(token: "claude", displayName: "Claude Code"),
        partnerPane: WorkflowDetectedAgent(token: "codex", displayName: "Codex"),
      ]
    }

    nonisolated let nextRunID = LockIsolated(UUID())
    nonisolated let beforeToken = LockIsolated<(@Sendable () throws -> Void)?>(nil)

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }

    func write(_ yaml: String, to name: String, scope: WorkflowScope = .repo) throws {
      let directory = scope == .repo ? WorkflowSources.repoDirectory(root: repoRoot) : userWorkflows
      let bundle = directory.appending(path: "\(name).pwlworkflow")
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      try Data(yaml.utf8).write(to: bundle.appending(path: "workflow.yaml"))
    }

    var worktree: Worktree {
      Worktree(
        id: "wt-1", name: "feature", detail: "", workingDirectory: repoRoot,
        repositoryRootURL: repoRoot)
    }

    func snapshot() -> WorkflowRuntimeSnapshot {
      func pane(_ id: UUID, handle: Int) -> TargetResolutionSnapshot.Pane {
        TargetResolutionSnapshot.Pane(
          id: id, handle: handle, title: "pane \(handle)",
          cwd: repoRoot.path(percentEncoded: false),
          isFocusedInTab: handle == 1,
          surfaceView: GhosttySurfaceView(
            runtime: GhosttyRuntime(), workingDirectory: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
            skipsSurfaceCreationForTesting: true))
      }
      let tab = TargetResolutionSnapshot.Tab(
        id: tabID, handle: 1, title: "Tab", selected: true,
        panes: [
          pane(authorPane, handle: 1), pane(partnerPane, handle: 2), pane(shellPane, handle: 3),
        ],
        focusedPaneID: authorPane)
      let worktree = TargetResolutionSnapshot.Worktree(
        id: "wt-1", name: "feature", path: repoRoot.path(percentEncoded: false),
        rootPath: repoRoot.path(percentEncoded: false), kind: .git, tabs: [tab])
      return WorkflowRuntimeSnapshot(
        resolution: TargetResolutionSnapshot(worktrees: [worktree], focusedWorktreeID: "wt-1"),
        paneByShellPID: [:],
        bundleWorkflowsURL: nil,
        userWorkflowsURL: userWorkflows,
        disabledWorkflowIDs: disabled,
        bundledSkillIDs: [],
        knownAgents: ["codex", "claude", "amp"],
        installedAgents: nil,
        enabledProfiles: [])
    }

    var environment: WorkflowAdmissionEnvironment {
      WorkflowAdmissionEnvironment(
        profiles: [
          AgentProfile(
            id: WorkflowRunAdmissionTests.claudeID, name: "Claude Code", runtime: .claude),
          AgentProfile(id: WorkflowRunAdmissionTests.codexID, name: "Codex", runtime: .codex),
          AgentProfile(id: WorkflowRunAdmissionTests.ampID, name: "Amp", runtime: .amp),
        ],
        recommendation: { [self] _ in (designated, nil) },
        rememberedBinding: { [self] key in remembered[key] },
        detectedAgent: { [self] id in agents[id] },
        pendingDispatchID: { [self] id in pendingDispatches[id] },
        busySurfaceIDs: busy,
        worktree: { [self] id in id == "wt-1" ? worktree : nil },
        branchName: { _ in "feat/x" },
        makeLaunchPlan: { [self] profile in
          plannedProfiles.append(profile.name)
          return AgentProfileLaunchPlan(
            profileID: profile.id, profileName: profile.name, runtime: profile.runtime,
            invocation: AgentInvocation(
              executable: profile.runtime.rawValue, arguments: ["placeholder"]),
            commandEnvironmentTokens: [], placement: .split, splitDirection: .right,
            surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: "placeholder"],
            dedicatedHome: nil)
        },
        now: Date(timeIntervalSince1970: 1_760_000_000),
        makeRunID: { [self] in
          nextRunID.withValue { value in
            defer { value = UUID() }
            return value
          }
        },
        makeToken: { [self] in
          try? beforeToken.value?()
          return "TOKEN"
        })
    }

    func source(pane: UUID?, isCaller: Bool = true) -> WorkflowRunSource {
      WorkflowRunSource(
        worktree: snapshot().resolution.worktrees[0], paneID: pane, paneIsCaller: isCaller)
    }
  }

  private func admit(
    _ fixture: Fixture, workflow: String, pane: UUID?, isCaller: Bool = true, roles: [String] = [],
    inputs: [String] = [], skips: [String] = []
  ) -> Result<WorkflowAdmittedRun, WorkflowAdmissionFailure> {
    WorkflowRunAdmission.admit(
      WorkflowInput(
        action: .run, workflow: workflow, roleBindings: roles, inputValues: inputs,
        skippedSteps: skips),
      source: fixture.source(pane: pane, isCaller: isCaller),
      snapshot: fixture.snapshot(),
      environment: fixture.environment)
  }

  private func code(_ result: Result<WorkflowAdmittedRun, WorkflowAdmissionFailure>) -> String? {
    if case .failure(let failure) = result { return failure.code }
    return nil
  }

  @Test(arguments: ["save", "launch"])
  func shippedHandoffResolvesOnlyTheSelectedPath(next: String) throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let yaml = try String(
      contentsOf: root.appending(path: "Resources/workflows/handoff.pwlworkflow/workflow.yaml"), encoding: .utf8
    )
    .replacing("id: prowl.handoff", with: "id: handoff")
    try fixture.write(yaml, to: "handoff")
    let admitted = try admit(
      fixture, workflow: "handoff", pane: fixture.authorPane,
      roles: next == "launch" ? ["receiver=Codex"] : [], inputs: ["next=\(next)"]
    ).get()
    #expect(admitted.session.run.selfInitiatedLine?.contains("prowl workflow deliver -") == true)
    #expect((admitted.session.run.bindings["receiver"] != nil) == (next == "launch"))
    #expect(fixture.plannedProfiles.isEmpty == (next == "save"))
  }

  @Test func testActionTreatsJSONInputAsLiteralData() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.contextOnly, to: "context")
    let admitted = try WorkflowRunAdmission.admit(
      WorkflowInput(
        action: .run, workflow: "context", testAction: "builtin:collect-worktree-context",
        actionInputs: ["root": .string("{{ literal.directory }}")]),
      source: fixture.source(pane: nil), snapshot: fixture.snapshot(), environment: fixture.environment
    ).get()
    #expect(
      admitted.effects.contains(
        .runAction(
          stepID: "action-test", actionID: "builtin:collect-worktree-context",
          inputs: ["root": .string("{{ literal.directory }}")])))
  }

  @Test func sourceContextPreservesTheInitiatingTab() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.contextOnly, to: "context")
    let admitted = try admit(fixture, workflow: "context", pane: fixture.authorPane).get()
    #expect(
      try WorkflowExpression.evaluate("context.initiator.tab_id", values: admitted.session.run.stepValues)
        == .string(fixture.tabID.uuidString))
  }

  @Test func aCompleteRequestFreezesEveryBindingAndWritesTheInitialRecord() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    let expectedRunID = fixture.nextRunID.value
    let admitted = try admit(
      fixture, workflow: "review", pane: fixture.authorPane,
      roles: ["partner=p2", "reviewer=Codex"],
      inputs: ["rounds=3"]
    ).get()
    let run = admitted.session.run
    #expect(run.id == expectedRunID)
    #expect(run.context.scope == .repo(repositoryID: fixture.repoRoot.path(percentEncoded: false)))
    #expect(run.context.worktree.branch == "feat/x")
    #expect(run.inputs["rounds"] == "3")
    #expect(
      run.bindings["author"]
        == .current(
          WorkflowPaneIdentity(
            surfaceID: fixture.authorPane,
            tabID: fixture.tabID, handle: "p1",
            displayName: "Claude Code", agent: "claude")))
    #expect(run.bindings["partner"]?.pane?.handle == "p2")
    #expect(
      run.bindings["reviewer"]?.profile
        == WorkflowProfileBinding(id: Self.codexID, name: "Codex", agent: "codex"))
    #expect(admitted.session.launchPlans["reviewer"]?.profileID == Self.codexID)
    #expect(admitted.session.bindingMemoryKeys["reviewer"]?.role == "reviewer")
    #expect(admitted.callerRole == "author")
    #expect(
      run.selfInitiatedLine?.contains("PROWL_WORKFLOW_TOKEN=TOKEN prowl workflow deliver -") == true)
    #expect(
      run.phase == .injecting(ordinal: 1), "self-initiated: the activation opens without typing")
    #expect(fixture.plannedProfiles == ["Codex"])
    let record = try admitted.session.store.readRecord(runID: run.id)
    #expect(record.run.status.state == "running")
    #expect(record.bindings["reviewer"]?.profile?.name == "Codex")
  }

  @Test func anExplicitPaneThatIsNotTheCallerIsNotSelfInitiated() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    let admitted = try admit(
      fixture, workflow: "review", pane: fixture.authorPane, isCaller: false, roles: ["partner=p2"]
    ).get()
    #expect(admitted.callerRole == nil)
    #expect(admitted.session.run.selfInitiatedLine == nil)
    #expect(admitted.session.run.phase == .waitingForRole(role: "author", ordinal: 1))
  }

  @Test func definitionSelectionCoversIdNameShadowingValidityAndEnabledState() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.contextOnly, to: "context")
    try fixture.write(
      Self.contextOnly.replacing("id: context", with: "id: other"), to: "other", scope: .user)
    try fixture.write(
      Self.contextOnly.replacing("id: context", with: "id: broken").replacing(
        "collect-worktree-context", with: "nope"), to: "broken")

    #expect(
      code(admit(fixture, workflow: "missing", pane: fixture.authorPane))
        == CLIErrorCode.workflowNotFound)
    #expect(
      code(admit(fixture, workflow: "Context", pane: fixture.authorPane))
        == CLIErrorCode.invalidArgument)
    #expect(code(admit(fixture, workflow: "other", pane: fixture.authorPane)) == nil)
    let broken = admit(fixture, workflow: "broken", pane: fixture.authorPane)
    #expect(code(broken) == CLIErrorCode.workflowInvalid)
    if case .failure(let failure) = broken {
      #expect(failure.details?.valid == false)
    }
    fixture.disabled = [
      WorkflowPreferenceKey.make(
        scope: .repo(repositoryID: fixture.repoRoot.path(percentEncoded: false)),
        workflowID: "context")
    ]
    #expect(
      code(admit(fixture, workflow: "context", pane: fixture.authorPane))
        == CLIErrorCode.workflowDisabled)
  }

  @Test func aCurrentRoleNeedsAPaneAndADetectedAgentOnlyWhenItIsMessaged() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    try fixture.write(Self.contextOnly, to: "context")
    #expect(code(admit(fixture, workflow: "review", pane: nil)) == CLIErrorCode.sourceRequired)
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.shellPane, roles: ["partner=p2"]))
        == CLIErrorCode.agentNotFound)
    // A context-only workflow never delivers to its current role: a bare shell is a valid source.
    let admitted = try admit(fixture, workflow: "context", pane: fixture.shellPane).get()
    #expect(admitted.session.run.bindings["author"]?.pane?.displayName == "shell")
    #expect(admitted.session.run.bindings["author"]?.pane?.agent == nil)
    // `--skip brief` removes the only message to the current role, so the shell is fine there too.
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.shellPane, roles: ["partner=p2"],
          skips: ["brief"])) == CLIErrorCode.invalidArgument,
      "brief feeds launch, so it cannot be skipped")
  }

  @Test func oneRunPerPaneIsEnforcedForCurrentAndPickRoles() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    fixture.busy = [fixture.authorPane]
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"]))
        == CLIErrorCode.paneBusy)
    fixture.busy = [fixture.partnerPane]
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"]))
        == CLIErrorCode.paneBusy)
  }

  /// A pane that still holds a pending dispatch cannot open an activation (#733 D4); refusing at
  /// admission is what keeps a run from looping on `roleBusy` against a record nobody completes.
  @Test func panesHoldingAPendingDispatchAreRefusedForCurrentAndPickRoles() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    fixture.pendingDispatches = [fixture.authorPane: "launch-dispatch"]
    let current = admit(
      fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"])
    #expect(code(current) == CLIErrorCode.dispatchPending)
    if case .failure(let failure) = current {
      #expect(failure.message.contains("launch-dispatch"))
    }
    fixture.pendingDispatches = [fixture.partnerPane: "reviewer-dispatch"]
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"]))
        == CLIErrorCode.dispatchPending)
  }

  @Test func pickRolesNeedAnExplicitAgentPaneInTheSourceWorktree() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.authorPane))
        == CLIErrorCode.invalidArgument)
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p9"]))
        == CLIErrorCode.targetNotFound)
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p3"]))
        == CLIErrorCode.agentNotFound)
    #expect(
      code(admit(fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p1"]))
        == CLIErrorCode.invalidArgument)
    let byUUID = admit(
      fixture, workflow: "review", pane: fixture.authorPane,
      roles: ["partner=\(fixture.partnerPane.uuidString)"])
    #expect(code(byUUID) == nil)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2", "author=p2"])
      ) == CLIErrorCode.invalidArgument)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2", "ghost=p2"]))
        == CLIErrorCode.invalidArgument)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane,
          roles: ["partner=p2", "partner=p2"])) == CLIErrorCode.invalidArgument)
  }

  @Test func launchRolesResolveOverridesRememberedAndRecommendedProfiles() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    // Recommended: the designated profile of the repository.
    fixture.designated = Self.codexID
    let recommended = try admit(
      fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"]
    ).get()
    #expect(recommended.session.run.bindings["reviewer"]?.profile?.id == Self.codexID)
    // Remembered beats recommended.
    let key = try #require(recommended.session.bindingMemoryKeys["reviewer"])
    fixture.remembered[key] = Self.claudeID
    let remembered = try admit(
      fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"]
    ).get()
    #expect(remembered.session.run.bindings["reviewer"]?.profile?.id == Self.claudeID)
    // An explicit override beats both; by UUID or name.
    let byName = try admit(
      fixture, workflow: "review", pane: fixture.authorPane,
      roles: ["partner=p2", "reviewer=Codex"]
    ).get()
    #expect(byName.session.run.bindings["reviewer"]?.profile?.id == Self.codexID)
    let byID = try admit(
      fixture, workflow: "review", pane: fixture.authorPane,
      roles: ["partner=p2", "reviewer=\(Self.codexID.uuidString)"]
    ).get()
    #expect(byID.session.run.bindings["reviewer"]?.profile?.id == Self.codexID)
    // `auto` falls through the tiers; an unknown name is PROFILE_NOT_FOUND.
    let auto = try admit(
      fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2", "reviewer=auto"]
    ).get()
    #expect(auto.session.run.bindings["reviewer"]?.profile?.id == Self.claudeID)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane,
          roles: ["partner=p2", "reviewer=Nope"])) == CLIErrorCode.profileNotFound)
    // An override the role rejects (Amp is not in `agents`) is logged and falls through.
    let fallen = try admit(
      fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2", "reviewer=Amp"]
    ).get()
    #expect(fallen.session.run.bindings["reviewer"]?.profile?.id == Self.claudeID)
    #expect(
      fallen.effects.first
        == .log(
          "Role 'reviewer': the requested profile was not used (its agent 'amp' is not allowed by the role); "
            + "resolved 'Claude Code' (remembered)."
        ))
  }

  @Test func aWorkflowWithoutACurrentRoleRunsFromAWorktreeAndAsksWhenNothingResolves() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.worktreeOnly, to: "launch-only")
    let admitted = try admit(fixture, workflow: "launch-only", pane: nil, isCaller: false).get()
    #expect(admitted.callerRole == nil)
    #expect(
      admitted.session.run.bindings["worker"]?.profile?.id == Self.claudeID,
      "first enabled profile is Recommended")
    #expect(admitted.session.run.phase == .launching(ordinal: 1))
    // Restrict the role to Amp, whose runtime cannot start with a prompt: the resolver reaches `.ask`.
    try fixture.write(
      Self.worktreeOnly.replacing("source: launch", with: "source: launch\n    agents: [amp]"),
      to: "launch-only")
    #expect(
      code(admit(fixture, workflow: "launch-only", pane: nil, isCaller: false))
        == CLIErrorCode.profileNotFound)
  }

  @Test func rejectedStartLeavesNoHistory() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    let storage = WorkflowHistoryStorage(baseURL: fixture.root.appending(path: "history"))
    withDependencies {
      $0[WorkflowHistoryStorageKey.self] = storage
    } operation: {
      #expect(
        code(
          admit(
            fixture, workflow: "review", pane: fixture.authorPane,
            roles: ["partner=p2"], inputs: ["rounds=9"])) == CLIErrorCode.invalidArgument)
    }
    #expect(try storage.directories().isEmpty)
  }

  @Test func initialRecordFailureLeavesNoHistory() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    let storage = WorkflowHistoryStorage(baseURL: fixture.root.appending(path: "history"))
    let directory = storage.directory(
      root: fixture.repoRoot, createdAt: fixture.environment.now, runID: fixture.nextRunID.value)
    fixture.beforeToken.setValue {
      try FileManager.default.createDirectory(
        at: directory.appending(path: "run.json"), withIntermediateDirectories: true)
    }
    withDependencies {
      $0[WorkflowHistoryStorageKey.self] = storage
    } operation: {
      #expect(
        code(
          admit(
            fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"]))
          == CLIErrorCode.workflowFailed)
    }
    #expect(try storage.directories().isEmpty)
  }

  @Test func duplicateRunIDFailurePreservesExistingHistory() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    let storage = WorkflowHistoryStorage(baseURL: fixture.root.appending(path: "history"))
    let directory = storage.directory(
      root: fixture.repoRoot, createdAt: fixture.environment.now, runID: fixture.nextRunID.value)
    try storage.prepare(directory)
    let marker = directory.appending(path: "existing.txt")
    try Data("existing".utf8).write(to: marker)
    withDependencies {
      $0[WorkflowHistoryStorageKey.self] = storage
    } operation: {
      #expect(
        code(
          admit(
            fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"]))
          == CLIErrorCode.workflowFailed)
    }
    #expect(try Data(contentsOf: marker) == Data("existing".utf8))
  }

  @Test func startTimeValidationMapsToInvalidArgument() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(Self.review, to: "review")
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"],
          inputs: ["rounds=9"])) == CLIErrorCode.invalidArgument)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"],
          inputs: ["nope=1"])) == CLIErrorCode.invalidArgument)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"],
          inputs: ["rounds"])) == CLIErrorCode.invalidArgument)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"],
          skips: ["ghost"])) == CLIErrorCode.invalidArgument)
    #expect(
      code(
        admit(
          fixture, workflow: "review", pane: fixture.authorPane, roles: ["partner=p2"],
          skips: ["ping"])) == CLIErrorCode.invalidArgument, "ping awaits nothing")
  }
}
