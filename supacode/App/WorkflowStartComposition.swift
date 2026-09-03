// supacode/App/WorkflowStartComposition.swift
// Live assembly of WorkflowStartClient (docs-ai 063 C2). The GUI start path reads the same
// catalog, resolver, and settings the CLI path reads, and submits through
// WorkflowRuntimeCoordinator.run — admission stays the single authority (011 decision 1).

import ComposableArchitecture
import Foundation

extension SupacodeApp {
  @MainActor
  static func makeWorkflowStartClient(
    terminalManager: WorktreeTerminalManager,
    storeBox: SupacodeAppStoreBox,
    coordinatorBox: WorkflowCoordinatorBox,
    reservations: WorkflowPaneReservations
  ) -> WorkflowStartClient {
    let client = WorkflowStartClient(
      catalog: { worktreeID in
        guard let appStore = storeBox.store else { return [] }
        let snapshot = makeWorkflowRuntimeSnapshot(appStore: appStore, terminalManager: terminalManager)
        guard let entries = try? workflowCatalogEntries(worktreeID: worktreeID, snapshot: snapshot) else {
          return []
        }
        return entries.compactMap { startCatalogItem($0, snapshot: snapshot) }
      },
      context: { workflowKey, worktreeID, preferredSource in
        guard let appStore = storeBox.store else { return nil }
        let snapshot = makeWorkflowRuntimeSnapshot(appStore: appStore, terminalManager: terminalManager)
        return makeWorkflowStartContext(
          workflowKey: workflowKey, worktreeID: worktreeID, preferredSourceSurfaceID: preferredSource,
          assembly: WorkflowStartAssembly(
            snapshot: snapshot, appStore: appStore, terminalManager: terminalManager,
            reservations: reservations))
      },
      run: { request in
        guard let appStore = storeBox.store, let coordinator = coordinatorBox.coordinator else {
          return .failed(
            code: CLIErrorCode.transportFailed, message: "Workflow runtime is not available.")
        }
        let snapshot = makeWorkflowRuntimeSnapshot(appStore: appStore, terminalManager: terminalManager)
        guard let worktree = snapshot.resolution.worktrees.first(where: { $0.id == request.worktreeID })
        else {
          return .failed(
            code: CLIErrorCode.targetNotFound, message: "The source worktree is no longer available.")
        }
        let source = WorkflowRunSource(
          worktree: worktree, paneID: request.sourceSurfaceID, paneIsCaller: false)
        let input = WorkflowInput(
          action: .run,
          target: request.sourceSurfaceID.map { .pane($0.uuidString) } ?? .worktree(request.worktreeID),
          workflow: request.workflowID,
          roleBindings: request.roleBindings,
          inputValues: request.inputValues,
          skippedSteps: request.skippedSteps)
        let response = await coordinator.run(input, source: source, snapshot: snapshot)
        if response.ok { return .started }
        return .failed(
          code: response.error?.code ?? CLIErrorCode.transportFailed,
          message: response.error?.message ?? "The workflow could not be started.")
      }
    )
    // Views outside the store scope (popover, context menu) resolve the global default,
    // so the assembled client must be published there too.
    WorkflowStartClientRegistry.shared.client = client
    return client
  }

  // MARK: - Catalog

  @MainActor
  private static func workflowCatalogEntries(
    worktreeID: String, snapshot: WorkflowRuntimeSnapshot
  ) throws -> [WorkflowCatalogEntry] {
    let worktree = snapshot.resolution.worktrees.first { $0.id == worktreeID }
    let repoURL = worktree.map {
      WorkflowSources.repoDirectory(root: URL(filePath: $0.rootPath, directoryHint: .isDirectory))
    }
    let sources = WorkflowSources(
      bundle: snapshot.bundleWorkflowsURL, user: snapshot.userWorkflowsURL, repo: repoURL)
    return try WorkflowDiscovery.catalog(sources: sources) { scope in
      WorkflowValidationContext(
        scope: scope,
        bundledSkillIDs: snapshot.bundledSkillIDs,
        knownAgents: snapshot.knownAgents,
        installedAgents: snapshot.installedAgents,
        enabledProfiles: snapshot.enabledProfiles
      )
    }
  }

  /// nil hides the entry everywhere: shadowed duplicates and definitions disabled in Settings
  /// (011 decision 3). A file that fails validation stays listed (the popover dims it); one
  /// that does not even parse keeps a file-based key so the popover can still name it.
  @MainActor
  private static func startCatalogItem(
    _ entry: WorkflowCatalogEntry, snapshot: WorkflowRuntimeSnapshot
  ) -> WorkflowStartCatalogItem? {
    guard !entry.shadowed else { return nil }
    let file = entry.file
    guard let id = file.id else {
      let filename = file.url.lastPathComponent
      return WorkflowStartCatalogItem(
        key: "\(file.scope.rawValue)/file:\(filename)", workflowID: filename, name: filename,
        workflowDescription: nil, validationFailure: "Cannot parse the file.")
    }
    let key = WorkflowCommandHandler.disabledKey(scope: file.scope, id: id)
    guard !snapshot.disabledWorkflowIDs.contains(key) else { return nil }
    let errors = file.diagnostics.errorCount
    return WorkflowStartCatalogItem(
      key: key,
      workflowID: id,
      name: file.definition?.name ?? id,
      workflowDescription: file.definition?.description,
      validationFailure: file.isValid ? nil : "\(errors) validation error\(errors == 1 ? "" : "s")")
  }

  // MARK: - Context

  /// The app-side facts one start-context assembly reads.
  struct WorkflowStartAssembly {
    let snapshot: WorkflowRuntimeSnapshot
    let appStore: StoreOf<AppFeature>
    let terminalManager: WorktreeTerminalManager
    let reservations: WorkflowPaneReservations
  }

  @MainActor
  private static func makeWorkflowStartContext(
    workflowKey: String,
    worktreeID: String,
    preferredSourceSurfaceID: UUID?,
    assembly: WorkflowStartAssembly
  ) -> WorkflowStartContext? {
    let snapshot = assembly.snapshot
    let appStore = assembly.appStore
    let terminalManager = assembly.terminalManager
    let reservations = assembly.reservations
    guard
      let entries = try? workflowCatalogEntries(worktreeID: worktreeID, snapshot: snapshot),
      let entry = entries.first(where: { candidate in
        startCatalogItem(candidate, snapshot: snapshot)?.key == workflowKey
      }),
      let item = startCatalogItem(entry, snapshot: snapshot),
      let definition = entry.file.definition,
      let worktree = snapshot.resolution.worktrees.first(where: { $0.id == worktreeID }),
      let domainWorktree = resolveCLITerminalWorktree(
        id: worktreeID, repositories: Array(appStore.state.repositories.repositories))
    else { return nil }

    @Shared(.userGlobalSettings) var settings

    let workflowRuns = appStore.state.workflowRuns
    let busySurfaceIDs = Set(
      workflowRuns.paneOwners.compactMap { surfaceID, runID in
        workflowRuns.sessions[runID]?.run.status.isTerminal == false ? surfaceID : nil
      }
    ).union(reservations.pending(for: workflowRuns, isLive: { terminalManager.isSurfaceLive($0) }))

    let agentEntries = appStore.state.repositories.activeAgents.entries.filter {
      $0.worktreeID == worktreeID
    }
    let panesByID: [UUID: TargetResolutionSnapshot.Pane] = Dictionary(
      worktree.tabs.flatMap(\.panes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    func candidate(surfaceID: UUID) -> WorkflowStartPaneCandidate? {
      guard let pane = panesByID[surfaceID] else { return nil }
      let agent = agentEntries.first { $0.surfaceID == surfaceID }
      return WorkflowStartPaneCandidate(
        surfaceID: surfaceID,
        handle: pane.handle.map { "p\($0)" },
        agentToken: agent?.agent.rawValue,
        agentDisplayName: agent?.agent.displayName,
        paneTitle: pane.title)
    }

    let agentCandidates = agentEntries.compactMap { candidate(surfaceID: $0.surfaceID) }
      .filter { !busySurfaceIDs.contains($0.surfaceID) }

    var source: WorkflowStartSource?
    if let currentRole = definition.roles.first(where: { $0.source == .current }) {
      var candidates = agentCandidates
      let preferred = preferredSourceSurfaceID ?? focusedSurfaceID(of: worktree)
      if let preferred, !candidates.contains(where: { $0.surfaceID == preferred }),
        preferredSourceSurfaceID != nil || !busySurfaceIDs.contains(preferred),
        let extra = candidate(surfaceID: preferred)
      {
        // The focused pane may be a bare shell (a valid source while no delivery survives),
        // and an explicitly pinned Active Agents pane stays the fixed source even while it
        // is bound to a run — admission answers with the CLI's own PANE_BUSY instead of the
        // sheet pre-judging it (011 decision 1).
        candidates.insert(extra, at: 0)
      }
      let preselected = candidates.contains { $0.surfaceID == preferred } ? preferred : nil
      source = WorkflowStartSource(
        roleName: currentRole.name,
        candidates: candidates,
        preselectedSurfaceID: preselected,
        isPreselectionFixed: preferredSourceSurfaceID != nil && preselected != nil)
    }

    let bindOverride = settings.workflowBindMode(for: workflowKey)
    let runScope = WorkflowRunAdmission.runScope(entry.file.scope, worktree: domainWorktree)
    let launchRoles = makeStartLaunchRoles(
      definition: definition, scope: runScope, bindOverride: bindOverride,
      repositoryRootURL: URL(filePath: worktree.rootPath, directoryHint: .isDirectory),
      settings: settings)

    let pickRoles: [WorkflowStartPickRole] = definition.roles.compactMap { role in
      guard role.source == .pick else { return nil }
      return WorkflowStartPickRole(name: role.name, candidates: agentCandidates)
    }

    let cliStatus = CLIInstallClient.liveValue.installationStatus(cliDefaultInstallPath)
    let cliInstalled = cliStatus != .notInstalled

    return WorkflowStartContext(
      item: item,
      definition: definition,
      worktreeID: worktreeID,
      worktreeName: worktree.name,
      source: source,
      launchRoles: launchRoles,
      pickRoles: pickRoles,
      cliInstalled: cliInstalled,
      bindModeOverride: bindOverride,
      cliServiceFailure: CLIServiceStatusPublisher.shared.status.failureDescription)
  }

  /// dsl-spec §3 binding resolution, presented: the resolver's pre-selection per launch role,
  /// every enabled profile as a picker candidate with its rejection reason, and the suggestion
  /// the inline create block starts from.
  @MainActor
  private static func makeStartLaunchRoles(
    definition: WorkflowDefinition,
    scope: WorkflowRunScope,
    bindOverride: WorkflowBindModeOverride.Mode?,
    repositoryRootURL: URL,
    settings: UserGlobalSettings
  ) -> [WorkflowStartLaunchRole] {
    @Shared(.userRepositorySettings(repositoryRootURL)) var repositorySettings
    let resolverContext = WorkflowBindingResolverContext(
      profiles: settings.agentProfiles,
      designatedProfileID: repositorySettings.defaultAgentProfileID,
      lastLaunchedProfileID: repositorySettings.lastLaunchedAgentProfileID)
    return definition.roles.compactMap { role in
      guard role.source == .launch, let requirements = role.launch else { return nil }
      let memoryKey = WorkflowBindingResolver.memoryKey(
        scope: scope, workflowID: definition.id, role: role)
      let remembered = settings.rememberedWorkflowBinding(for: memoryKey)
      let result = WorkflowBindingResolver.resolve(
        role: role, remembered: remembered, override: nil, context: resolverContext)
      var resolvedProfileID: UUID?
      var suggestion: WorkflowProfileSuggestion?
      if case .success(let binding) = result {
        switch binding.resolution {
        case .resolved(let profile, _): resolvedProfileID = profile.id
        case .ask(_, let suggested): suggestion = suggested
        }
      }
      let rejectedNote: String? =
        if case .success(let binding) = result, binding.rejected[.remembered] != nil {
          "The previously used profile no longer qualifies."
        } else { nil }
      let candidates = settings.agentProfiles.filter(\.isEnabled).map { profile in
        WorkflowStartLaunchRole.Candidate(
          profileID: profile.id,
          name: profile.name,
          agentToken: profile.runtime.agent.rawValue,
          unavailableReason: WorkflowBindingResolver.rejection(
            of: profile, requirements: requirements, context: resolverContext
          ).map { rejectionText($0, requirements: requirements) })
      }
      // "Create profile from suggestion…" is for when nothing matches (011 decision 4):
      // once an enabled, admissible profile already matches the suggestion exactly,
      // creating another indistinguishable one would only clutter Settings.
      let hasExactSuggestionMatch =
        requirements.suggest.map { suggested in
          settings.agentProfiles.contains { profile in
            profile.isEnabled
              && WorkflowBindingResolver.rejection(
                of: profile, requirements: requirements, context: resolverContext) == nil
              && WorkflowBindingResolver.matches(profile, suggestion: suggested)
          }
        } ?? false
      return WorkflowStartLaunchRole(
        name: role.name,
        effectiveBind: bindOverride.map { $0 == .auto ? WorkflowBindMode.auto : .ask } ?? requirements.bind,
        resolvedProfileID: resolvedProfileID,
        candidates: candidates,
        suggestion: hasExactSuggestionMatch ? nil : (suggestion ?? requirements.suggest),
        rejectedNote: rejectedNote)
    }
  }

  private static func focusedSurfaceID(of worktree: TargetResolutionSnapshot.Worktree) -> UUID? {
    let selectedTab = worktree.tabs.first { $0.selected } ?? worktree.tabs.first
    return selectedTab?.focusedPaneID
  }

  private static func rejectionText(
    _ rejection: WorkflowBindingRejection, requirements: WorkflowLaunchRequirements
  ) -> String {
    switch rejection {
    case .missing:
      return "The profile no longer exists."
    case .disabled:
      return "Disabled in Settings."
    case .agentNotAllowed:
      let allowed = (requirements.agents ?? []).joined(separator: ", ")
      return "This role needs \(allowed.isEmpty ? "another agent" : allowed)."
    case .promptUnsupported:
      return "This profile's runtime cannot take a launch prompt."
    }
  }
}
