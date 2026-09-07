// supacode/CLIService/WorkflowRunAdmission.swift
// Preflight of `prowl workflow run` (docs-ai 063 B3, decisions W2/W4): the effective definition,
// source and worktree facts, binding legality (explicit `--role` overrides, remembered bindings,
// suggestion, Recommended), one run per pane, the frozen launch plans, and the run directory with
// its initial record. Nothing here touches a pane: a request that fails admission has no side
// effect beyond the run directory it may have created for a run that then started.

import Foundation
import ProwlCLIShared

/// The pane (or worktree only) the run is started from, as the handler resolved it.
struct WorkflowRunSource: Sendable {
  let worktree: TargetResolutionSnapshot.Worktree
  /// The pane the `current` role binds to; nil when the target named a worktree.
  let paneID: UUID?
  /// Whether `paneID` is the caller's own pane (a self-initiated run, dsl-spec §9).
  let paneIsCaller: Bool

  /// The repository root the source worktree belongs to (the 053 Recommended memory key).
  var repositoryRootURL: URL {
    URL(filePath: worktree.rootPath, directoryHint: .isDirectory)
  }
}

/// A detected agent in a pane, as admission needs it.
nonisolated struct WorkflowDetectedAgent: Equatable, Sendable {
  let token: String
  let displayName: String
}

/// Main-actor facts admission reads through closures so it stays testable without the app.
struct WorkflowAdmissionEnvironment {
  let profiles: [AgentProfile]
  /// The 053 Recommended inputs of a repository (designated, last launched), by repository root.
  let recommendation: @MainActor (URL) -> (designated: UUID?, lastLaunched: UUID?)
  let rememberedBinding: @MainActor (WorkflowBindingMemoryKey) -> UUID?
  let detectedAgent: @MainActor (UUID) -> WorkflowDetectedAgent?
  /// The pending dispatch record a pane holds, if any (#733 D4: one per surface).
  let pendingDispatchID: @MainActor (UUID) -> String?
  /// Panes bound in active runs (dsl-spec §10: one run per pane).
  let busySurfaceIDs: Set<UUID>
  let worktree: @MainActor (Worktree.ID) -> Worktree?
  let branchName: @MainActor (Worktree) -> String
  let makeLaunchPlan: @MainActor (AgentProfile) throws -> AgentProfileLaunchPlan
  let bundledSkill: @MainActor (String) -> BundledSkill?
  let now: Date
  let makeRunID: @Sendable () -> UUID
  let makeToken: @Sendable () -> String
  let limits: WorkflowDeliveryLimits

  init(
    profiles: [AgentProfile],
    recommendation: @escaping @MainActor (URL) -> (designated: UUID?, lastLaunched: UUID?) = { _ in
      (nil, nil)
    },
    rememberedBinding: @escaping @MainActor (WorkflowBindingMemoryKey) -> UUID? = { _ in nil },
    detectedAgent: @escaping @MainActor (UUID) -> WorkflowDetectedAgent?,
    pendingDispatchID: @escaping @MainActor (UUID) -> String? = { _ in nil },
    busySurfaceIDs: Set<UUID> = [],
    worktree: @escaping @MainActor (Worktree.ID) -> Worktree?,
    branchName: @escaping @MainActor (Worktree) -> String = { $0.name },
    makeLaunchPlan: @escaping @MainActor (AgentProfile) throws -> AgentProfileLaunchPlan,
    bundledSkill: @escaping @MainActor (String) -> BundledSkill? = { _ in nil },
    now: Date = Date(),
    makeRunID: @escaping @Sendable () -> UUID = { UUID() },
    makeToken: @escaping @Sendable () -> String = { UUID().uuidString },
    limits: WorkflowDeliveryLimits = WorkflowDeliveryLimits()
  ) {
    self.profiles = profiles
    self.recommendation = recommendation
    self.rememberedBinding = rememberedBinding
    self.detectedAgent = detectedAgent
    self.pendingDispatchID = pendingDispatchID
    self.busySurfaceIDs = busySurfaceIDs
    self.worktree = worktree
    self.branchName = branchName
    self.makeLaunchPlan = makeLaunchPlan
    self.bundledSkill = bundledSkill
    self.now = now
    self.makeRunID = makeRunID
    self.makeToken = makeToken
    self.limits = limits
  }
}

struct WorkflowAdmittedRun: Sendable {
  let session: WorkflowRunSession
  let effects: [WorkflowRunEffect]
  /// The caller pane's role when the run was started from a bound pane.
  let callerRole: String?
}

nonisolated struct WorkflowAdmissionFailure: Error, Equatable, Sendable {
  let code: String
  let message: String
  /// The validate payload of an invalid definition (`WORKFLOW_INVALID`).
  var details: WorkflowValidatePayload?
}

@MainActor
enum WorkflowRunAdmission {
  private struct Arguments {
    let inputs: [String: String]
    let overrides: [String: String]
    let skipped: Set<String>
  }

  /// The whole preflight; on success the run directory holds `run.json` and the reducer can own
  /// the session.
  static func admit(
    _ input: WorkflowInput,
    source: WorkflowRunSource,
    snapshot: WorkflowRuntimeSnapshot,
    environment: WorkflowAdmissionEnvironment
  ) -> Result<WorkflowAdmittedRun, WorkflowAdmissionFailure> {
    guard let name = input.workflow, !name.isEmpty else {
      return .failure(
        .init(code: CLIErrorCode.invalidArgument, message: "A workflow id or name is required."))
    }
    let entry: WorkflowCatalogEntry
    switch effectiveEntry(named: name, worktree: source.worktree, snapshot: snapshot) {
    case .failure(let failure): return .failure(failure)
    case .success(let value): entry = value
    }
    guard var definition = entry.file.definition, entry.file.isValid else {
      return .failure(
        .init(
          code: CLIErrorCode.workflowInvalid,
          message:
            "Workflow '\(name)' has \(entry.file.diagnostics.errorCount) validation error(s); fix the file first.",
          details: WorkflowValidatePayload(file: entry.file)))
    }
    if let actionID = input.testAction {
      let localID = actionID.hasPrefix("local:") ? String(actionID.dropFirst(6)) : ""
      guard actionID == "builtin:collect-worktree-context" || entry.file.actions[localID] != nil else {
        return .failure(.init(code: CLIErrorCode.invalidArgument, message: "Unknown bundle action '\(actionID)'."))
      }
      definition = WorkflowDefinition(
        id: definition.id, name: definition.name + " · Action Test",
        steps: [.init(id: "action-test", action: .action(id: actionID, inputs: input.actionInputs ?? [:]))])
    }
    guard
      let preferenceKey = WorkflowPreferenceKey.make(
        scope: entry.file.scope,
        workflowID: definition.id,
        repositoryRootPath: source.worktree.rootPath)
    else {
      return .failure(
        .init(
          code: CLIErrorCode.workflowFailed,
          message: "The workflow preference scope is unavailable."))
    }
    if snapshot.disabledWorkflowIDs.contains(preferenceKey) {
      return .failure(
        .init(
          code: CLIErrorCode.workflowDisabled,
          message: "Workflow '\(definition.id)' is disabled in Settings."))
    }
    guard let worktree = environment.worktree(source.worktree.id) else {
      return .failure(
        .init(
          code: CLIErrorCode.targetNotFound, message: "The source worktree is no longer available.")
      )
    }
    let arguments: Arguments
    switch parseArguments(input, definition: definition) {
    case .failure(let failure): return .failure(failure)
    case .success(let value): arguments = value
    }
    var binder = RoleBinder(
      definition: definition,
      source: source,
      environment: environment,
      overrides: arguments.overrides,
      scope: runScope(entry.file.scope, worktree: worktree),
      deliversToCurrent: deliversToCurrentRole(definition, skipped: arguments.skipped))
    for role in definition.roles {
      if let failure = binder.bind(role) {
        return .failure(failure)
      }
    }
    return start(
      Admission(
        definition: definition, entry: entry, worktree: worktree, arguments: arguments,
        binder: binder, source: source, literalActionInputs: input.testAction != nil,
        environment: environment))
  }

  // MARK: - Start

  private struct Admission {
    let definition: WorkflowDefinition
    let entry: WorkflowCatalogEntry
    let worktree: Worktree
    let arguments: Arguments
    let binder: RoleBinder
    let source: WorkflowRunSource
    let literalActionInputs: Bool
    let environment: WorkflowAdmissionEnvironment
  }

  private static func start(_ admission: Admission) -> Result<
    WorkflowAdmittedRun, WorkflowAdmissionFailure
  > {
    let (definition, entry, worktree, arguments) = (
      admission.definition, admission.entry, admission.worktree, admission.arguments
    )
    let (binder, source, environment) = (admission.binder, admission.source, admission.environment)
    var context = WorkflowRunContext(
      scope: binder.scope,
      definitionPath: entry.file.url.path(percentEncoded: false),
      worktree: WorkflowRunWorktree(
        id: worktree.id, name: worktree.name, branch: environment.branchName(worktree),
        path: worktree.workingDirectory.path(percentEncoded: false)))
    context.sourcePaneID = source.paneID
    context.sourceTabID = source.worktree.tabs.first { tab in tab.panes.contains { $0.id == source.paneID } }?.id
    context.literalActionInputs = admission.literalActionInputs
    if let failure = approvalFailure(entry.file) { return .failure(failure) }
    let runID = environment.makeRunID()
    let storage = WorkflowHistoryStorage.configured
    let directory = storage.directory(root: context.worktree.rootURL, createdAt: environment.now, runID: runID)
    context.historyDirectory = directory
    var coordination: WorkflowHistoryLock?
    var allocated = false
    var published = false
    defer {
      if allocated && !published {
        do {
          if FileManager.default.fileExists(atPath: directory.path) {
            _ = try storage.files(in: directory)
            try FileManager.default.removeItem(at: directory)
          }
        } catch {
          SupaLogger("WorkflowAdmission").warning("Cannot remove unpublished run at \(directory.path): \(error)")
        }
        context.occupancy?.finish()
      }
      coordination?.close()
    }
    do {
      coordination = try storage.coordinate()
      guard try storage.find(runID) == nil else { throw WorkflowHistoryError.invalidRecord }
      allocated = true
      try storage.prepare(directory)
      context.occupancy = try WorkflowRunOccupancy(storage.occupy(directory))
    } catch {
      return .failure(.init(code: CLIErrorCode.workflowFailed, message: "History storage is unavailable: \(error)"))
    }
    if entry.file.snapshot != nil {
      do {
        try WorkflowRunStore(rootURL: context.worktree.rootURL, directory: directory).ensureLayout(runID: runID)
        context.bundle = try WorkflowPreparedBundle(
          source: entry.file,
          directory: directory.appending(
            path: "definition"),
          environment: ProcessInfo.processInfo.environment)
      } catch {
        return .failure(.init(code: CLIErrorCode.workflowFailed, message: "Bundle preparation failed: \(error)"))
      }
    }
    let now = environment.now
    let started: (machine: WorkflowRunMachine, effects: [WorkflowRunEffect])
    do {
      started = try WorkflowRunMachine.start(
        WorkflowRunStartRequest(
          definition: definition,
          runID: runID,
          context: context,
          bindings: binder.bindings,
          inputs: arguments.inputs,
          skippedSteps: arguments.skipped,
          selfInitiated: source.paneIsCaller && binder.callerRole != nil,
          limits: environment.limits),
        now: { now },
        makeToken: environment.makeToken)
    } catch {
      return .failure(describe(error))
    }
    var skills: [String: BundledSkill] = [:]
    for step in definition.flattenedSteps {
      if case .launch(_, _, let skill?, _) = step.action,
        let bundled = environment.bundledSkill(skill)
      {
        skills[skill] = bundled
      }
    }
    let session = WorkflowRunSession(
      run: started.machine.run,
      worktree: worktree,
      launchPlans: binder.launchPlans,
      bindingMemoryKeys: binder.memoryKeys,
      skills: skills,
      limits: environment.limits)
    // Layout and the initial record are part of the reply (decision W1).
    do {
      try session.store.ensureLayout(runID: runID)
      try session.store.writeRecord(WorkflowRunRecord(run: session.run))
    } catch {
      let message = "The run directory could not be created at \(directory.path): \(error)"
      return .failure(.init(code: CLIErrorCode.workflowFailed, message: message))
    }
    published = true
    let effects = binder.startLog.map(WorkflowRunEffect.log) + started.effects
    return .success(
      WorkflowAdmittedRun(session: session, effects: effects, callerRole: binder.callerRole))
  }

  private static func approvalFailure(_ file: WorkflowSourceFile) -> WorkflowAdmissionFailure? {
    guard let snapshot = file.snapshot, !file.actions.isEmpty else { return nil }
    do {
      guard try WorkflowBundleApprovalStore().isApproved(snapshot) else {
        return .init(
          code: "WORKFLOW_APPROVAL_REQUIRED",
          message: "Review and approve this script bundle in Settings > Agents > Workflows, then start the run again.")
      }
      return nil
    } catch {
      return .init(code: CLIErrorCode.workflowFailed, message: "Bundle approval could not be checked: \(error)")
    }
  }

  // MARK: - Arguments

  private static func parseArguments(
    _ input: WorkflowInput, definition: WorkflowDefinition
  ) -> Result<Arguments, WorkflowAdmissionFailure> {
    let inputs: [String: String]
    switch parsePairs(input.inputValues, what: "--input") {
    case .failure(let failure): return .failure(failure)
    case .success(let value): inputs = value
    }
    let overrides: [String: String]
    switch parsePairs(input.roleBindings, what: "--role") {
    case .failure(let failure): return .failure(failure)
    case .success(let value): overrides = value
    }
    for role in overrides.keys.sorted() where definition.role(named: role) == nil {
      return .failure(
        .init(
          code: CLIErrorCode.invalidArgument,
          message: "Workflow '\(definition.id)' declares no role '\(role)'."))
    }
    return .success(
      Arguments(inputs: inputs, overrides: overrides, skipped: Set(input.skippedSteps)))
  }

  /// `name=value` pairs; duplicates and malformed entries are `INVALID_ARGUMENT`.
  static func parsePairs(_ values: [String], what: String) -> Result<
    [String: String], WorkflowAdmissionFailure
  > {
    var pairs: [String: String] = [:]
    for value in values {
      guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
        return .failure(
          .init(
            code: CLIErrorCode.invalidArgument,
            message: "\(what) expects <name>=<value>, got '\(value)'."))
      }
      let name = String(value[..<separator])
      guard pairs[name] == nil else {
        return .failure(
          .init(
            code: CLIErrorCode.invalidArgument, message: "\(what) \(name) was given more than once."
          ))
      }
      pairs[name] = String(value[value.index(after: separator)...])
    }
    return .success(pairs)
  }

  static func parseLaunchOverride(_ value: String?) -> Result<
    WorkflowBindingOverride?, WorkflowAdmissionFailure
  > {
    guard let value else { return .success(nil) }
    if value == "auto" { return .success(.auto) }
    if let id = UUID(uuidString: value) { return .success(.profileID(id)) }
    guard !value.isEmpty else {
      return .failure(
        .init(
          code: CLIErrorCode.invalidArgument,
          message: "--role <launch role>= needs a profile name, UUID, or auto."))
    }
    return .success(.profileName(value))
  }

  // MARK: - Bindings

  /// Freezes one binding per role, in declaration order, so the first failure names the first role.
  private struct RoleBinder {
    let definition: WorkflowDefinition
    let source: WorkflowRunSource
    let environment: WorkflowAdmissionEnvironment
    let overrides: [String: String]
    let scope: WorkflowRunScope
    let deliversToCurrent: Bool

    private(set) var bindings: [String: WorkflowRoleBinding] = [:]
    private(set) var launchPlans: [String: AgentProfileLaunchPlan] = [:]
    private(set) var memoryKeys: [String: WorkflowBindingMemoryKey] = [:]
    private(set) var startLog: [String] = []
    private(set) var callerRole: String?
    private var boundSurfaceIDs: Set<UUID> = []

    init(
      definition: WorkflowDefinition,
      source: WorkflowRunSource,
      environment: WorkflowAdmissionEnvironment,
      overrides: [String: String],
      scope: WorkflowRunScope,
      deliversToCurrent: Bool
    ) {
      self.definition = definition
      self.source = source
      self.environment = environment
      self.overrides = overrides
      self.scope = scope
      self.deliversToCurrent = deliversToCurrent
    }

    mutating func bind(_ role: WorkflowRoleDefinition) -> WorkflowAdmissionFailure? {
      switch role.source {
      case .current: bindCurrent(role)
      case .pick: bindPick(role)
      case .launch: bindLaunch(role)
      }
    }

    private mutating func bindCurrent(_ role: WorkflowRoleDefinition) -> WorkflowAdmissionFailure? {
      guard overrides[role.name] == nil else {
        return .init(
          code: CLIErrorCode.invalidArgument,
          message: "Role '\(role.name)' is the current pane; it takes no --role override.")
      }
      guard let paneID = source.paneID else {
        return .init(
          code: CLIErrorCode.sourceRequired,
          message:
            "Workflow '\(definition.id)' runs from a pane (its '\(role.name)' role is the current pane): "
            + "run it inside the pane or pass a pane target (pN / pane UUID).")
      }
      guard !environment.busySurfaceIDs.contains(paneID) else {
        return .init(
          code: CLIErrorCode.paneBusy,
          message: "The source pane already belongs to another workflow run.")
      }
      if let dispatchID = environment.pendingDispatchID(paneID) {
        return pendingDispatch(dispatchID, pane: "The source pane")
      }
      let agent = environment.detectedAgent(paneID)
      if deliversToCurrent, agent == nil {
        return .init(
          code: CLIErrorCode.agentNotFound,
          message: "Workflow '\(definition.id)' delivers a message to its '\(role.name)' role, "
            + "but the source pane hosts no detected agent.")
      }
      guard let identity = paneIdentity(paneID, agent: agent, worktree: source.worktree) else {
        return .init(
          code: CLIErrorCode.targetNotFound, message: "The source pane is no longer available.")
      }
      bindings[role.name] = .current(identity)
      boundSurfaceIDs.insert(paneID)
      if source.paneIsCaller { callerRole = role.name }
      return nil
    }

    private mutating func bindPick(_ role: WorkflowRoleDefinition) -> WorkflowAdmissionFailure? {
      guard let override = overrides[role.name] else {
        return .init(
          code: CLIErrorCode.invalidArgument,
          message:
            "Role '\(role.name)' is picked from an existing agent pane: pass --role \(role.name)=<pN|pane UUID>."
        )
      }
      guard let paneID = resolvePane(override, worktree: source.worktree) else {
        return .init(
          code: CLIErrorCode.targetNotFound,
          message:
            "No pane '\(override)' in worktree '\(source.worktree.name)' for role '\(role.name)'.")
      }
      guard paneID != source.paneID, !boundSurfaceIDs.contains(paneID) else {
        return .init(
          code: CLIErrorCode.invalidArgument,
          message: "Role '\(role.name)' cannot use a pane already bound in this run.")
      }
      guard !environment.busySurfaceIDs.contains(paneID) else {
        return .init(
          code: CLIErrorCode.paneBusy,
          message: "Pane '\(override)' already belongs to another workflow run.")
      }
      if let dispatchID = environment.pendingDispatchID(paneID) {
        return pendingDispatch(dispatchID, pane: "Pane '\(override)'")
      }
      guard let agent = environment.detectedAgent(paneID) else {
        return .init(
          code: CLIErrorCode.agentNotFound,
          message: "Pane '\(override)' hosts no detected agent for role '\(role.name)'."
        )
      }
      guard let identity = paneIdentity(paneID, agent: agent, worktree: source.worktree) else {
        return .init(
          code: CLIErrorCode.targetNotFound, message: "Pane '\(override)' is no longer available.")
      }
      bindings[role.name] = .pick(identity)
      boundSurfaceIDs.insert(paneID)
      return nil
    }

    /// A pane with a pending record cannot open an activation (#733 D4) — the record's owner
    /// must finish first; refusing here keeps the run from looping on `roleBusy`.
    private func pendingDispatch(_ dispatchID: String, pane: String) -> WorkflowAdmissionFailure {
      .init(
        code: CLIErrorCode.dispatchPending,
        message: "\(pane) still holds pending dispatch \(dispatchID); complete it "
          + "(`prowl agents dispatch-complete`) or abandon it (`prowl agents dispatch-abandon`) before starting a run."
      )
    }

    private mutating func bindLaunch(_ role: WorkflowRoleDefinition) -> WorkflowAdmissionFailure? {
      let override: WorkflowBindingOverride?
      switch parseLaunchOverride(overrides[role.name]) {
      case .failure(let failure): return failure
      case .success(let value): override = value
      }
      let key = WorkflowBindingResolver.memoryKey(
        scope: scope, workflowID: definition.id, role: role)
      let recommendation = environment.recommendation(source.repositoryRootURL)
      let resolution = WorkflowBindingResolver.resolve(
        role: role,
        remembered: environment.rememberedBinding(key),
        override: override,
        context: WorkflowBindingResolverContext(
          profiles: environment.profiles,
          designatedProfileID: recommendation.designated,
          lastLaunchedProfileID: recommendation.lastLaunched))
      let profile: AgentProfile
      switch resolution {
      case .failure(let error):
        return .init(code: error.code, message: describe(error, role: role.name))
      case .success(let resolved):
        switch resolved.resolution {
        case .ask:
          return .init(
            code: CLIErrorCode.profileNotFound,
            message: "No enabled Agent Profile satisfies role '\(role.name)'"
              + (role.launch?.agents.map { " (agents: \($0.joined(separator: ", ")))" } ?? "")
              + "; pass --role \(role.name)=<profile name|UUID> or create one in Settings.")
        case .resolved(let value, let tier):
          profile = value
          for rejectedTier in [WorkflowBindingTier.override, .remembered] {
            guard let rejection = resolved.rejected[rejectedTier] else { continue }
            let what = rejectedTier == .override ? "requested" : "remembered"
            startLog.append(
              "Role '\(role.name)': the \(what) profile was not used (\(describe(rejection))); "
                + "resolved '\(profile.name)' (\(describe(tier))).")
          }
        }
      }
      do {
        launchPlans[role.name] = try environment.makeLaunchPlan(profile)
      } catch {
        return .init(
          code: CLIErrorCode.workflowFailed,
          message: "Profile '\(profile.name)' cannot be launched for role '\(role.name)': \(error)")
      }
      memoryKeys[role.name] = key
      bindings[role.name] = .launch(
        WorkflowProfileBinding(
          id: profile.id, name: profile.name, agent: profile.runtime.agent.rawValue), pane: nil)
      return nil
    }
  }

  // MARK: - Definition

  /// The winning (unshadowed) definition with this id, or the unique one with this name.
  static func effectiveEntry(
    named name: String, worktree: TargetResolutionSnapshot.Worktree,
    snapshot: WorkflowRuntimeSnapshot
  ) -> Result<WorkflowCatalogEntry, WorkflowAdmissionFailure> {
    let sources = WorkflowSources(
      bundle: snapshot.bundleWorkflowsURL,
      user: snapshot.userWorkflowsURL,
      repo: WorkflowSources.repoDirectory(
        root: URL(filePath: worktree.rootPath, directoryHint: .isDirectory)))
    let catalog: [WorkflowCatalogEntry]
    do {
      catalog = try WorkflowDiscovery.catalog(sources: sources) { scope in
        WorkflowValidationContext(
          scope: scope,
          bundledSkillIDs: snapshot.bundledSkillIDs,
          knownAgents: snapshot.knownAgents,
          installedAgents: snapshot.installedAgents,
          enabledProfiles: snapshot.enabledProfiles)
      }
    } catch {
      return .failure(
        .init(code: CLIErrorCode.workflowFailed, message: "Failed to discover workflows: \(error)"))
    }
    let visible = catalog.filter { !$0.shadowed }
    if let byID = visible.first(where: { $0.file.id == name }) {
      return .success(byID)
    }
    let byName = visible.filter { $0.file.definition?.name == name }
    switch byName.count {
    case 0:
      return .failure(
        .init(
          code: CLIErrorCode.workflowNotFound,
          message:
            "No workflow '\(name)' is visible to worktree '\(worktree.name)'; see `prowl workflow list`."
        ))
    case 1:
      return .success(byName[0])
    default:
      let ids = byName.compactMap(\.file.id).sorted().joined(separator: ", ")
      return .failure(
        .init(
          code: CLIErrorCode.invalidArgument,
          message: "Several workflows are named '\(name)' (\(ids)); use the id."))
    }
  }

  // MARK: - Helpers

  static func runScope(_ scope: WorkflowScope, worktree: Worktree) -> WorkflowRunScope {
    switch scope {
    case .bundle: .bundle
    case .user: .user
    case .repo: .repo(repositoryID: worktree.repositoryRootURL.path(percentEncoded: false))
    }
  }

  /// dsl-spec §3: a `current` role needs a detected agent only when a `message` to it survives the skips.
  nonisolated static func deliversToCurrentRole(
    _ definition: WorkflowDefinition, skipped: Set<String>
  ) -> Bool {
    guard let current = definition.roles.first(where: { $0.source == .current }) else {
      return false
    }
    return definition.flattenedSteps.contains { step in
      if case .message(let role, _, _) = step.action, role == current.name {
        return !skipped.contains(step.id)
      }
      return false
    }
  }

  /// `pN` or a pane UUID inside the source worktree only.
  static func resolvePane(_ reference: String, worktree: TargetResolutionSnapshot.Worktree) -> UUID? {
    let panes = worktree.tabs.flatMap(\.panes)
    if let id = UUID(uuidString: reference) {
      return panes.first { $0.id == id }?.id
    }
    guard reference.hasPrefix("p"), let handle = Int(reference.dropFirst()) else { return nil }
    return panes.first { $0.handle == handle }?.id
  }

  static func paneIdentity(
    _ paneID: UUID, agent: WorkflowDetectedAgent?, worktree: TargetResolutionSnapshot.Worktree
  ) -> WorkflowPaneIdentity? {
    for tab in worktree.tabs {
      guard let pane = tab.panes.first(where: { $0.id == paneID }) else { continue }
      return WorkflowPaneIdentity(
        surfaceID: paneID,
        tabID: tab.id,
        handle: pane.handle.map { "p\($0)" } ?? paneID.uuidString,
        displayName: agent?.displayName ?? "shell",
        agent: agent?.token)
    }
    return nil
  }

  private static func describe(_ error: WorkflowBindingError, role: String) -> String {
    switch error {
    case .profileNotFound(let reference):
      "No Agent Profile '\(reference)' for role '\(role)'; see `prowl profiles list`."
    case .profileNotUnique(let reference):
      "Several Agent Profiles are named '\(reference)'; use the profile UUID."
    case .roleNotLaunchable: "Role '\(role)' is not a launch role."
    }
  }

  private static func describe(_ rejection: WorkflowBindingRejection) -> String {
    switch rejection {
    case .missing: "it no longer exists"
    case .disabled: "it is disabled"
    case .agentNotAllowed(let agent): "its agent '\(agent)' is not allowed by the role"
    case .promptUnsupported: "its runtime cannot start with a prompt"
    }
  }

  private static func describe(_ tier: WorkflowBindingTier) -> String {
    switch tier {
    case .override: "override"
    case .remembered: "remembered"
    case .suggestion: "suggested"
    case .recommended: "recommended"
    }
  }

  private static func describe(_ error: WorkflowRunStartError) -> WorkflowAdmissionFailure {
    switch error {
    case .invalidInput(let name, let reason):
      .init(code: CLIErrorCode.invalidArgument, message: "Input '\(name)': \(reason)")
    case .unsafePath(let path):
      .init(
        code: CLIErrorCode.unsafePath,
        message: "The worktree path cannot be rendered on one line: \(path)")
    case .unknownSkipStep(let step):
      .init(code: CLIErrorCode.invalidArgument, message: "--skip \(step): no such step.")
    case .skipNotExpecting(let step):
      .init(
        code: CLIErrorCode.invalidArgument,
        message: "--skip \(step): only steps that await an output can be skipped.")
    case .skipNotAllowed(let step, let dependent):
      .init(
        code: CLIErrorCode.invalidArgument,
        message: "--skip \(step): step '\(dependent)' needs its output.")
    case .missingBinding(let role):
      .init(code: CLIErrorCode.invalidArgument, message: "Role '\(role)' has no binding.")
    }
  }
}
