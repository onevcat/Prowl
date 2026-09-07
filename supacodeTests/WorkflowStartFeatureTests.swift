import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Sharing
import Testing

@testable import supacode

@MainActor
struct WorkflowStartFeatureTests {
  static let review = """
    schema: prowl.workflow/v1
    id: review
    name: Review
    inputs:
      focus: { type: string, default: "everything" }
      goal: { type: string }
    roles:
      author:
        source: current
      reviewer:
        source: launch
        agents: [pi]
    steps:
      - id: brief
        message: author
        text: "Brief on {{ inputs.goal }}."
        expect: { delivery: brief }
      - id: launch
        launch: reviewer
        prompt: "Read {{ deliveries.brief.path }}."
    """

  static let skippableNote = """
    schema: prowl.workflow/v1
    id: note-flow
    name: Note Flow
    roles:
      author:
        source: current
      runner:
        source: launch
        bind: auto
    steps:
      - id: note
        message: author
        text: "Write a note."
        expect: { delivery: note }
      - id: launch
        launch: runner
        prompt: "Just do it."
    """

  static let profileID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  static let agentPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  static let shellPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  static let agentPane = WorkflowStartPaneCandidate(
    surfaceID: agentPaneID, handle: "p1", agentToken: "claude",
    agentDisplayName: "Claude Code", paneTitle: "claude")
  static let shellPane = WorkflowStartPaneCandidate(
    surfaceID: shellPaneID, handle: "p2", agentToken: nil, agentDisplayName: nil, paneTitle: "zsh")

  private func makeContext(
    yaml: String = review,
    preselected: UUID? = agentPaneID,
    resolvedProfileID: UUID? = nil,
    suggestion: WorkflowProfileSuggestion? = nil,
    bindModeOverride: WorkflowBindModeOverride.Mode? = nil,
    candidateUnavailableReason: String? = nil,
    includeCandidates: Bool = true,
    cliServiceFailure: String? = nil
  ) throws -> WorkflowStartContext {
    let definition = try #require(WorkflowDocumentParser.parse(yaml).definition)
    let launchRoles = definition.roles.filter { $0.source == .launch }.map { role in
      WorkflowStartLaunchRole(
        name: role.name,
        effectiveBind: bindModeOverride == .auto ? .auto : (role.launch?.bind ?? .ask),
        resolvedProfileID: resolvedProfileID,
        candidates: includeCandidates
          ? [
            WorkflowStartLaunchRole.Candidate(
              profileID: Self.profileID, name: "Pi Reviewer", agentToken: "pi",
              unavailableReason: candidateUnavailableReason)
          ] : [],
        suggestion: suggestion,
        rejectedNote: nil)
    }
    return WorkflowStartContext(
      item: WorkflowStartCatalogItem(
        key: "user/\(definition.id)",
        scope: .user,
        fileURL: URL(filePath: "/tmp/\(definition.id).yaml"),
        workflowID: definition.id,
        name: definition.name,
        workflowDescription: nil,
        icon: definition.icon,
        validationFailure: nil),
      definition: definition,
      worktreeID: "/tmp/wt/", worktreeName: "main",
      source: WorkflowStartSource(
        roleName: "author",
        candidates: [Self.agentPane, Self.shellPane],
        preselectedSurfaceID: preselected),
      launchRoles: launchRoles,
      pickRoles: [],
      cliInstalled: true,
      bindModeOverride: bindModeOverride,
      cliServiceFailure: cliServiceFailure)
  }

  @Test func scriptApprovalUsesTheSharedReviewWithoutStartingARun() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.review.write(to: directory.appending(path: "workflow.yaml"), atomically: true, encoding: .utf8)
    let snapshot = try WorkflowBundleSnapshot.read(directory)
    let script = try WorkflowScriptAction.parse(
      """
      schema: prowl.action/v1
      name: Echo
      input_schema: {type: object}
      output_schema: {type: object}
      backend: {type: script, interpreter: /bin/sh, entrypoint: main.sh}
      """, id: "echo", files: ["actions/echo/main.sh": Data("true".utf8)])
    let review = WorkflowBundleReview(snapshot: snapshot, scripts: [script], changes: [], approved: false)
    var context = try makeContext(
      yaml: Self.review.replacing("goal: { type: string }", with: "goal: { type: string, default: Verify }"),
      resolvedProfileID: Self.profileID, bindModeOverride: .auto)
    #expect(context.canStartImmediately)
    context.requiresBundleApproval = true
    #expect(!context.canStartImmediately)
    let approvals = LockIsolated<[String]>([])
    let store = TestStore(initialState: WorkflowStartFeature.State(context: context)) {
      WorkflowStartFeature()
    } withDependencies: {
      $0[WorkflowBundleReviewClient.self].load = { _, _ in review }
      $0[WorkflowBundleReviewClient.self].approve = { candidate in
        approvals.withValue { $0.append(candidate.fingerprint) }
      }
    }
    store.exhaustivity = .off
    #expect(!store.state.canRun)
    await store.send(.reviewBundleTapped)
    #expect(store.state.bundleReview == review)
    await store.send(.approveBundleTapped)
    #expect(approvals.value == [snapshot.fingerprint])
    #expect(store.state.bundleReview?.approved == true)
    #expect(store.state.canRun)
    #expect(!store.state.isSubmitting)
    await store.send(.dismissBundleReview)
    #expect(store.state.bundleReview == nil)
  }

  @Test func approvalRequiredResponseBlocksAnotherRunUntilReview() async throws {
    let context = try makeContext(
      yaml: Self.review.replacing("goal: { type: string }", with: "goal: { type: string, default: Verify }"),
      resolvedProfileID: Self.profileID)
    let store = TestStore(initialState: WorkflowStartFeature.State(context: context)) { WorkflowStartFeature() }
    store.exhaustivity = .off
    #expect(store.state.canRun)
    await store.send(.runResponse(.failed(code: "WORKFLOW_APPROVAL_REQUIRED", message: "Review this bundle.")))
    #expect(!store.state.canRun)
  }

  @Test func initPrefillsFromTheResolverAnswers() throws {
    let context = try makeContext(resolvedProfileID: Self.profileID)
    let state = WorkflowStartFeature.State(context: context)

    #expect(state.selectedSourceSurfaceID == Self.agentPaneID)
    #expect(state.launchSelections == ["reviewer": Self.profileID])
    #expect(state.inputValues == ["focus": "everything"])
    #expect(!state.dontAskAgain)
  }

  @Test func canRunNeedsSelectionsAndRequiredInputs() throws {
    let context = try makeContext(resolvedProfileID: Self.profileID)
    var state = WorkflowStartFeature.State(context: context)

    #expect(!state.canRun)  // `goal` has no default
    state.inputValues["goal"] = "ship C2"
    #expect(state.canRun)
    state.launchSelections = [:]
    #expect(!state.canRun)
  }

  @Test func unreachableSocketBlocksRun() throws {
    let context = try makeContext(
      resolvedProfileID: Self.profileID,
      cliServiceFailure: "Another Prowl instance owns the socket.")
    var state = WorkflowStartFeature.State(context: context)
    state.inputValues["goal"] = "x"
    #expect(!state.canRun)
  }

  @Test func unavailableProfileSelectionBlocksRun() throws {
    let context = try makeContext(
      resolvedProfileID: Self.profileID, candidateUnavailableReason: "This role needs pi.")
    var state = WorkflowStartFeature.State(context: context)
    state.inputValues["goal"] = "x"
    #expect(!state.canRun)
  }

  @Test func skippingTheOnlyDeliveryMakesABareShellSourceValid() async throws {
    let context = try makeContext(
      yaml: Self.skippableNote, preselected: Self.shellPaneID,
      resolvedProfileID: Self.profileID)
    let store = TestStore(initialState: WorkflowStartFeature.State(context: context)) {
      WorkflowStartFeature()
    }

    #expect(!store.state.canRun)  // bare shell + a surviving delivery
    await store.send(.skipToggled(stepID: "note")) {
      $0.skippedSteps = ["note"]
    }
    #expect(store.state.canRun)
  }

  @Test func aFailedInlineInstallShowsTheInstallerMessage() async throws {
    let context = try makeContext(resolvedProfileID: Self.profileID)
    let store = TestStore(initialState: WorkflowStartFeature.State(context: context)) {
      WorkflowStartFeature()
    } withDependencies: {
      $0[CLIInstallClient.self].install = { _ in
        throw CLIInstallError(message: "A file already exists at /usr/local/bin/prowl.")
      }
    }

    await store.send(.installCLITapped)
    await store.receive(\.cliInstallCompleted.failure) {
      $0.submissionError = "A file already exists at /usr/local/bin/prowl."
    }
  }

  @Test func endsRunSkipsAreNeverArmed() async throws {
    let context = try makeContext(resolvedProfileID: Self.profileID)
    let store = TestStore(initialState: WorkflowStartFeature.State(context: context)) {
      WorkflowStartFeature()
    }
    // `brief` feeds the launch prompt: skipping it at start is refused by admission (§9).
    await store.send(.skipToggled(stepID: "brief"))
    #expect(store.state.skippedSteps.isEmpty)
  }

  @Test func runSubmitsTheCLIVocabularyAndPersistsDontAskAgain() async throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    let submitted = LockIsolated<WorkflowStartRequest?>(nil)
    let context = try makeContext(resolvedProfileID: Self.profileID)

    try await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    } operation: {
      var initial = WorkflowStartFeature.State(context: context)
      initial.inputValues["goal"] = "ship C2"
      initial.inputValues["focus"] = "everything"  // untouched default: must not submit
      initial.dontAskAgain = true
      let store = TestStore(initialState: initial) {
        WorkflowStartFeature()
      } withDependencies: {
        $0[WorkflowStartClient.self].run = { request in
          submitted.setValue(request)
          return .started
        }
      }

      await store.send(.runTapped) {
        $0.isSubmitting = true
      }
      await store.receive(.runResponse(.started)) {
        $0.isSubmitting = false
      }
      await store.receive(.delegate(.started))

      let request = try #require(submitted.value)
      #expect(request.workflowID == "review")
      #expect(request.sourceSurfaceID == Self.agentPaneID)
      #expect(request.roleBindings == ["reviewer=\(Self.profileID.uuidString)"])
      #expect(request.inputValues == ["goal=ship C2"])
      #expect(request.skippedSteps.isEmpty)

      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      #expect(settings.workflowBindMode(for: "user/review") == .auto)
    }
  }

  @Test func uncheckingDontAskAgainClearsAPersistedAuto() async throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    let context = try makeContext(resolvedProfileID: Self.profileID, bindModeOverride: .auto)

    await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    } operation: {
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      $settings.withLock { $0.setWorkflowBindMode(.auto, for: "user/review") }

      var initial = WorkflowStartFeature.State(context: context)
      initial.inputValues["goal"] = "x"
      #expect(initial.dontAskAgain)  // reflects the stored override
      initial.dontAskAgain = false
      let store = TestStore(initialState: initial) {
        WorkflowStartFeature()
      } withDependencies: {
        $0[WorkflowStartClient.self].run = { _ in .started }
      }

      await store.send(.runTapped) { $0.isSubmitting = true }
      await store.receive(.runResponse(.started)) { $0.isSubmitting = false }
      await store.receive(.delegate(.started))

      #expect(settings.workflowBindMode(for: "user/review") == nil)
    }
  }

  @Test func failedSubmissionShowsTheError() async throws {
    let context = try makeContext(resolvedProfileID: Self.profileID)
    var initial = WorkflowStartFeature.State(context: context)
    initial.inputValues["goal"] = "x"
    let store = TestStore(initialState: initial) {
      WorkflowStartFeature()
    } withDependencies: {
      $0[WorkflowStartClient.self].run = { _ in
        .failed(code: "PANE_BUSY", message: "The source pane already belongs to a run.")
      }
    }

    await store.send(.runTapped) { $0.isSubmitting = true }
    let failure = WorkflowStartOutcome.failed(
      code: "PANE_BUSY", message: "The source pane already belongs to a run.")
    await store.receive(.runResponse(failure)) {
      $0.isSubmitting = false
      $0.submissionError = "The source pane already belongs to a run."
    }
  }

  @Test func createFromSuggestionPersistsARealProfileAndSelectsIt() async throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    let suggestion = WorkflowProfileSuggestion(
      agent: "pi", model: nil, reasoningEffort: "xhigh", executionMode: "standard")
    let context = try makeContext(suggestion: suggestion)

    try await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    } operation: {
      let store = TestStore(initialState: WorkflowStartFeature.State(context: context)) {
        WorkflowStartFeature()
      } withDependencies: {
        $0.uuid = .incrementing
      }

      await store.send(.createSuggestionTapped(role: "reviewer")) {
        $0.creatingSuggestionForRole = "reviewer"
        $0.suggestionProfileName = "Reviewer (Pi)"
      }
      let expected = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
      await store.send(.createSuggestionConfirmed) {
        $0.creatingSuggestionForRole = nil
        $0.suggestionProfileName = ""
        $0.launchSelections = ["reviewer": expected]
        $0.createdCandidatesByRole = [
          "reviewer": [
            WorkflowStartLaunchRole.Candidate(
              profileID: expected, name: "Reviewer (Pi)", agentToken: "pi",
              unavailableReason: nil)
          ]
        ]
      }

      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      let created = try #require(settings.agentProfiles.first { $0.id == expected })
      #expect(created.name == "Reviewer (Pi)")
      #expect(created.runtime == .pi)
      #expect(created.reasoningEffort == "xhigh")
      #expect(created.isEnabled)
    }
  }

  @Test func createFromSuggestionEnablesRunWhenNoProfileMatched() async throws {
    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    let suggestion = WorkflowProfileSuggestion(agent: "pi")
    // The first-session path: no enabled profile qualifies for the role at all.
    let context = try makeContext(suggestion: suggestion, includeCandidates: false)

    await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    } operation: {
      var initial = WorkflowStartFeature.State(context: context)
      initial.inputValues["goal"] = "ship C2"
      let store = TestStore(initialState: initial) {
        WorkflowStartFeature()
      } withDependencies: {
        $0.uuid = .incrementing
      }
      store.exhaustivity = .off

      #expect(!store.state.canRun)
      await store.send(.createSuggestionTapped(role: "reviewer"))
      await store.send(.createSuggestionConfirmed)
      #expect(store.state.canRun)
      let created = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
      #expect(store.state.request.roleBindings == ["reviewer=\(created.uuidString)"])
    }
  }

  @Test func suggestionOutsideTheRoleAgentListOffersNoCreateAction() async throws {
    // dsl-spec §3: `agents: [pi]` with `suggest: { agent: claude }` is legal (validator
    // warns only); creating that profile would be refused by admission as agentNotAllowed,
    // so the sheet must not offer it — and a stray confirm must not persist anything.
    let context = try makeContext(
      suggestion: WorkflowProfileSuggestion(agent: "claude"), includeCandidates: false)
    let state = WorkflowStartFeature.State(context: context)
    #expect(!state.canCreateSuggestion(for: "reviewer"))

    let storage = UserGlobalSettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/prowl-global-settings-\(UUID().uuidString).json")
    await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.userGlobalSettingsURL = url
    } operation: {
      var initial = WorkflowStartFeature.State(context: context)
      initial.creatingSuggestionForRole = "reviewer"
      initial.suggestionProfileName = "Sneaky"
      let store = TestStore(initialState: initial) {
        WorkflowStartFeature()
      } withDependencies: {
        $0.uuid = .incrementing
      }
      await store.send(.createSuggestionConfirmed) {
        $0.creatingSuggestionForRole = nil
      }
      @Shared(.userGlobalSettings) var settings: UserGlobalSettings
      #expect(settings.agentProfiles.isEmpty)
    }
  }

  @Test func suggestionWithoutAnAgentOffersNoCreateAction() throws {
    // dsl-spec §3 allows a `suggest` that omits `agent`; it cannot form a profile, so the
    // sheet must not offer a dead Create action for it.
    let context = try makeContext(
      suggestion: WorkflowProfileSuggestion(reasoningEffort: "xhigh"), includeCandidates: false)
    let state = WorkflowStartFeature.State(context: context)
    #expect(!state.canCreateSuggestion(for: "reviewer"))

    let piContext = try makeContext(
      suggestion: WorkflowProfileSuggestion(agent: "pi"), includeCandidates: false)
    #expect(WorkflowStartFeature.State(context: piContext).canCreateSuggestion(for: "reviewer"))
  }
}
