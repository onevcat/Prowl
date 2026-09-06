// supacode/Features/Workflow/Reducer/WorkflowStartFeature.swift
// The start sheet's interaction state (docs-ai 063 C2, 011 decisions 2-6). The sheet gathers
// the same overrides/inputs/skips `workflow run` accepts and submits through
// WorkflowStartClient.run; it presents the resolver's answers and never re-derives eligibility.

import ComposableArchitecture
import Foundation
import ProwlCLIShared

@Reducer
struct WorkflowStartFeature {
  @ObservableState
  struct State: Equatable {
    let context: WorkflowStartContext
    var selectedSourceSurfaceID: UUID?
    /// Launch role name → chosen profile. Pre-filled from the resolver's answer.
    var launchSelections: [String: UUID]
    /// Pick role name → chosen pane.
    var pickSelections: [String: UUID] = [:]
    /// Input name → current value. Pre-filled from declared defaults.
    var inputValues: [String: String]
    var skippedSteps: Set<String> = []
    var dontAskAgain: Bool
    /// Candidates the sheet itself created from a suggestion, per role — the context's
    /// candidate list is immutable, and a profile created inline must be pickable and
    /// runnable immediately (review round 2 finding 1).
    var createdCandidatesByRole: [String: [WorkflowStartLaunchRole.Candidate]] = [:]
    /// The launch role whose inline "create from suggestion" confirm block is open.
    var creatingSuggestionForRole: String?
    var suggestionProfileName: String = ""
    var isSubmitting = false
    var submissionError: String?
    var requiresBundleApproval: Bool
    var bundleReview: WorkflowBundleReview?
    /// Starts as the context's snapshot and flips when the inline Install succeeds.
    var cliInstalled: Bool

    init(context: WorkflowStartContext) {
      self.context = context
      requiresBundleApproval = context.requiresBundleApproval
      cliInstalled = context.cliInstalled
      selectedSourceSurfaceID = context.source?.preselectedSurfaceID
      launchSelections = Dictionary(
        context.launchRoles.compactMap { role in role.resolvedProfileID.map { (role.name, $0) } },
        uniquingKeysWith: { first, _ in first })
      inputValues = Dictionary(
        context.definition.inputs.compactMap { input in
          input.defaultValue.map { (input.name, $0.stringValue) }
        },
        uniquingKeysWith: { first, _ in first })
      dontAskAgain = context.bindModeOverride == .auto
    }

    /// The role's picker candidates: the resolver's list plus anything created inline.
    func candidates(for role: WorkflowStartLaunchRole) -> [WorkflowStartLaunchRole.Candidate] {
      role.candidates + (createdCandidatesByRole[role.name] ?? [])
    }

    /// A suggestion can only form a profile when it names a known runtime AND the resulting
    /// profile would actually qualify for the role — judged by the same resolver rejection
    /// rule admission applies, so Create never manufactures a profile the run then refuses
    /// (dsl-spec §3 allows agent-less suggestions and agent/`agents` mismatches; the
    /// validator only warns about them).
    func canCreateSuggestion(for roleName: String) -> Bool {
      guard let role = context.launchRoles.first(where: { $0.name == roleName }),
        let agent = role.suggestion?.agent,
        let runtime = AgentProfileRuntime(rawValue: agent),
        let requirements = context.definition.roles.first(where: { $0.name == roleName })?.launch
      else { return false }
      let probe = AgentProfile(id: UUID(), name: "probe", runtime: runtime)
      return WorkflowBindingResolver.rejection(
        of: probe, requirements: requirements,
        context: WorkflowBindingResolverContext(profiles: [])) == nil
    }

    /// Whether the chosen source must host a detected agent, given the current skip choices.
    var sourceRequiresAgent: Bool {
      WorkflowRunAdmission.deliversToCurrentRole(context.definition, skipped: skippedSteps)
    }

    /// The §5 Skip rule for one step, aware of the other skips already chosen.
    func skipConsequence(for stepID: String) -> WorkflowSkipConsequence? {
      WorkflowRunMachine.startSkipConsequence(
        forStep: stepID, definition: context.definition,
        alreadySkipped: skippedSteps.subtracting([stepID]))
    }

    var canRun: Bool {
      guard !requiresBundleApproval, !isSubmitting, cliInstalled, context.cliServiceFailure == nil,
        context.item.isRunnable
      else {
        return false
      }
      if let source = context.source {
        guard let selected = selectedSourceSurfaceID,
          let candidate = source.candidates.first(where: { $0.surfaceID == selected })
        else { return false }
        if sourceRequiresAgent, candidate.agentToken == nil { return false }
      }
      for role in context.launchRoles {
        guard let chosen = launchSelections[role.name],
          let candidate = candidates(for: role).first(where: { $0.profileID == chosen }),
          candidate.unavailableReason == nil
        else { return false }
      }
      let picks = context.pickRoles.compactMap { pickSelections[$0.name] }
      guard picks.count == context.pickRoles.count, Set(picks).count == picks.count else {
        return false
      }
      if context.source != nil, let source = selectedSourceSurfaceID, picks.contains(source) {
        return false
      }
      for input in context.definition.inputs where input.defaultValue == nil {
        guard let value = inputValues[input.name],
          !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
      }
      return true
    }

    /// The submission in the CLI's own vocabulary (011 decision 1).
    var request: WorkflowStartRequest {
      WorkflowStartRequest(
        workflowID: context.item.workflowID,
        worktreeID: context.worktreeID,
        sourceSurfaceID: context.source != nil ? selectedSourceSurfaceID : nil,
        roleBindings: context.launchRoles.compactMap { role in
          launchSelections[role.name].map { "\(role.name)=\($0.uuidString)" }
        }
          + context.pickRoles.compactMap { role in
            pickSelections[role.name].map { "\(role.name)=\($0.uuidString)" }
          },
        inputValues: context.definition.inputs.compactMap { input in
          guard let value = inputValues[input.name] else { return nil }
          return value == input.defaultValue?.stringValue ? nil : "\(input.name)=\(value)"
        },
        skippedSteps: skippedSteps.sorted())
    }
  }

  enum Action: Equatable {
    case reviewBundleTapped
    case reviewFileSelected(String)
    case approveBundleTapped
    case dismissBundleReview
    case revealBundleTapped
    case sourceSelected(UUID?)
    case launchProfileSelected(role: String, profileID: UUID?)
    case pickPaneSelected(role: String, surfaceID: UUID?)
    case inputChanged(name: String, value: String)
    case skipToggled(stepID: String)
    case dontAskAgainToggled(Bool)
    case createSuggestionTapped(role: String)
    case suggestionNameChanged(String)
    case createSuggestionConfirmed
    case createSuggestionCancelled
    case installCLITapped
    case cliInstallCompleted(Result<String, CLIInstallError>)
    case cancelTapped
    case runTapped
    case runResponse(WorkflowStartOutcome)
    case delegate(Delegate)
  }

  enum Delegate: Equatable {
    case dismiss
    case started
  }

  @Dependency(WorkflowBundleReviewClient.self) var bundleClient
  @Dependency(WorkflowStartClient.self) var workflowStartClient
  @Dependency(CLIInstallClient.self) var cliInstallClient
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      handle(state: &state, action: action)
    }
  }

  private func handle(state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .reviewBundleTapped, .reviewFileSelected, .approveBundleTapped, .dismissBundleReview, .revealBundleTapped:
      return handleBundleReview(state: &state, action: action)
    case .sourceSelected, .launchProfileSelected, .pickPaneSelected, .inputChanged,
      .skipToggled, .dontAskAgainToggled:
      return handleEdit(state: &state, action: action)
    case .createSuggestionTapped, .suggestionNameChanged, .createSuggestionConfirmed,
      .createSuggestionCancelled:
      return handleSuggestion(state: &state, action: action)
    default:
      return handleRemainder(state: &state, action: action)
    }
  }

  private func handleBundleReview(state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .reviewBundleTapped:
      do { state.bundleReview = try bundleClient.load(state.context.item.fileURL, state.context.item.scope) } catch {
        state.submissionError = "\(error)"
      }
    case .reviewFileSelected(let path):
      if state.bundleReview?.filePaths.contains(path) == true { state.bundleReview?.selectedFile = path }
    case .approveBundleTapped:
      guard let review = state.bundleReview, !review.approved, !review.scripts.isEmpty else { return .none }
      do {
        try bundleClient.approve(review.snapshot)
        state.bundleReview?.approved = true
        state.bundleReview?.error = nil
        state.requiresBundleApproval = false
        state.submissionError = nil
      } catch { state.bundleReview?.error = "\(error)" }
    case .dismissBundleReview:
      if state.bundleReview?.approved == true { state.requiresBundleApproval = false }
      state.bundleReview = nil
    case .revealBundleTapped: bundleClient.reveal(state.context.item.fileURL)
    default: break
    }
    return .none
  }

  /// Selection, input, and skip edits: pure state changes with no effects.
  private func handleEdit(state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .sourceSelected(let surfaceID):
      guard state.context.source?.isPreselectionFixed != true else { return .none }
      state.selectedSourceSurfaceID = surfaceID
      return .none

    case .launchProfileSelected(let role, let profileID):
      state.launchSelections[role] = profileID
      return .none

    case .pickPaneSelected(let role, let surfaceID):
      state.pickSelections[role] = surfaceID
      return .none

    case .inputChanged(let name, let value):
      state.inputValues[name] = value
      return .none

    case .skipToggled(let stepID):
      if state.skippedSteps.contains(stepID) {
        state.skippedSteps.remove(stepID)
        return .none
      }
      // §9: a step without an `expect` offers no skip choice, and a skip whose output a
      // later step needs is refused by admission; the sheet shows the consequence and
      // never arms either.
      guard let consequence = state.skipConsequence(for: stepID) else { return .none }
      if case .endsRun = consequence { return .none }
      state.skippedSteps.insert(stepID)
      return .none

    case .dontAskAgainToggled(let isOn):
      state.dontAskAgain = isOn
      return .none

    default:
      assertionFailure("handle(state:action:) routes only edit actions here.")
      return .none
    }
  }

  /// The inline "create profile from suggestion" block (011 decision 4).
  private func handleSuggestion(state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .createSuggestionTapped(let role):
      state.creatingSuggestionForRole = role
      state.suggestionProfileName = Self.suggestedProfileName(role: role, state: state)
      return .none

    case .suggestionNameChanged(let name):
      state.suggestionProfileName = name
      return .none

    case .createSuggestionConfirmed:
      guard let roleName = state.creatingSuggestionForRole,
        state.canCreateSuggestion(for: roleName),
        let role = state.context.launchRoles.first(where: { $0.name == roleName }),
        let profile = Self.profile(
          from: role.suggestion, name: state.suggestionProfileName, id: uuid())
      else {
        state.creatingSuggestionForRole = nil
        return .none
      }
      // Synchronous inside the reducer, like AgentProfilesFeature.persist: a cancelled
      // effect must not drop the new profile.
      @Shared(.userGlobalSettings) var settings
      $settings.withLock {
        $0.agentProfiles = AgentProfile.normalizedProfiles($0.agentProfiles + [profile])
      }
      state.createdCandidatesByRole[roleName, default: []].append(
        WorkflowStartLaunchRole.Candidate(
          profileID: profile.id, name: profile.name,
          agentToken: profile.runtime.agent.rawValue, unavailableReason: nil))
      state.launchSelections[roleName] = profile.id
      state.creatingSuggestionForRole = nil
      state.suggestionProfileName = ""
      return .none

    case .createSuggestionCancelled:
      state.creatingSuggestionForRole = nil
      state.suggestionProfileName = ""
      return .none

    default:
      assertionFailure("handle(state:action:) routes only suggestion actions here.")
      return .none
    }
  }

  private func handleRemainder(state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .installCLITapped:
      return .run { [cliInstallClient] send in
        do {
          try await cliInstallClient.install(cliDefaultInstallPath)
          await send(.cliInstallCompleted(.success(cliDefaultInstallPath.path(percentEncoded: false))))
        } catch let error as CLIInstallError {
          await send(.cliInstallCompleted(.failure(error)))
        } catch {
          await send(.cliInstallCompleted(.failure(CLIInstallError(message: error.localizedDescription))))
        }
      }

    case .cliInstallCompleted(.success):
      state.cliInstalled = true
      return .none

    case .cliInstallCompleted(.failure(let error)):
      // The installer's own message names the conflict (a file in the way, a denied prompt);
      // a generic line would hide the recovery.
      state.submissionError = error.message
      return .none

    case .cancelTapped:
      return .send(.delegate(.dismiss))

    case .runTapped:
      guard state.canRun else { return .none }
      state.isSubmitting = true
      state.submissionError = nil
      let request = state.request
      return .run { send in
        await send(.runResponse(workflowStartClient.run(request)))
      }

    case .runResponse(.started):
      state.isSubmitting = false
      Self.persistBindModeChoice(state: state)
      return .send(.delegate(.started))

    case .runResponse(.failed(let code, let message)):
      state.isSubmitting = false
      state.submissionError = message
      if code == "WORKFLOW_APPROVAL_REQUIRED" { state.requiresBundleApproval = true }
      return .none

    case .delegate:
      return .none

    default:
      assertionFailure("handle(state:action:) routes edit and suggestion actions elsewhere.")
      return .none
    }
  }

  /// "Don't ask again" writes the tri-state override (011 decision 5): checked persists
  /// `auto`; unchecked clears a previously persisted `auto` and otherwise leaves the
  /// stored mode (D1's Settings control owns `ask`) alone.
  private static func persistBindModeChoice(state: State) {
    @Shared(.userGlobalSettings) var settings
    let key = state.context.item.key
    if state.dontAskAgain {
      $settings.withLock { $0.setWorkflowBindMode(.auto, for: key) }
    } else if state.context.bindModeOverride == .auto {
      $settings.withLock { $0.setWorkflowBindMode(nil, for: key) }
    }
  }

  private static func suggestedProfileName(role: String, state: State) -> String {
    let launchRole = state.context.launchRoles.first { $0.name == role }
    let runtimeName =
      launchRole?.suggestion?.agent
      .flatMap { AgentProfileRuntime(rawValue: $0) }
      .map { AgentRuntimeAdapterRegistry.displayName(for: $0) }
    let roleTitle = role.prefix(1).uppercased() + role.dropFirst()
    return runtimeName.map { "\(roleTitle) (\($0))" } ?? roleTitle
  }

  /// A real, Settings-manageable profile from the workflow author's `suggest` block.
  private static func profile(
    from suggestion: WorkflowProfileSuggestion?, name: String, id: UUID
  ) -> AgentProfile? {
    guard let suggestion, let agent = suggestion.agent,
      let runtime = AgentProfileRuntime(rawValue: agent)
    else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    return AgentProfile(
      id: id,
      name: trimmed,
      runtime: runtime,
      model: suggestion.model,
      reasoningEffort: suggestion.reasoningEffort,
      executionMode: suggestion.executionMode.flatMap { AgentExecutionMode(rawValue: $0) }
        ?? .standard)
  }
}
