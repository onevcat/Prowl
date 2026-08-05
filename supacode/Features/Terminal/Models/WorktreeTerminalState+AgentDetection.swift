import Foundation
import GhosttyKit

extension WorktreeTerminalState {
  func wakeAgentDetection(forSurfaceID surfaceID: UUID) {
    guard let view = surfaces[surfaceID],
      let tabId = tabId(containing: surfaceID)
    else {
      return
    }
    wakeAgentDetection(for: view, tabId: tabId)
  }

  func wakeAgentDetection(for view: GhosttySurfaceView, tabId: TerminalTabID, now: Date = Date()) {
    agentDetectionSchedules[view.id] = (agentDetectionSchedules[view.id] ?? .cold).warmed(now: now)
    if surfaceAgentStates[view.id] == nil {
      surfaceAgentStates[view.id] = PaneAgentState(lastChangedAt: now)
    }
    startAgentDetectionTaskIfNeeded(for: view, tabId: tabId)
  }

  func startAgentDetectionTaskIfNeeded(for view: GhosttySurfaceView, tabId: TerminalTabID) {
    guard agentDetectionTasks[view.id] == nil else { return }
    agentDetectionTasks[view.id] = Task { @MainActor [weak self, weak view] in
      while !Task.isCancelled {
        guard let self, let view, self.surfaces[view.id] != nil else { return }
        let hasAgent = await self.detectAgentState(for: view, tabId: tabId)
        let now = Date()
        // Titles land on the manager's own clock now, because a non-agent program
        // can strand one after this schedule goes cold. An entry cannot be
        // stranded that way: it exists only while a pane has a detected agent,
        // and that is exactly the condition keeping this loop warm. So the poll
        // stays the trailing flush here, and no second timer is needed.
        self.flushPendingAgentEntry(surfaceID: view.id, now: now)
        let schedule = self.agentDetectionSchedules[view.id] ?? .cold
        self.agentDetectionSchedules[view.id] =
          hasAgent ? schedule.observedAgent(now: now) : schedule.observedNoAgent(now: now)

        guard let interval = self.agentDetectionSchedules[view.id]?.nextInterval(now: now) else {
          self.finishColdAgentDetection(forSurfaceID: view.id)
          return
        }
        try? await Task.sleep(for: interval)
      }
    }
  }

  func finishColdAgentDetection(forSurfaceID surfaceID: UUID) {
    agentDetectionTasks.removeValue(forKey: surfaceID)
    agentDetectionSchedules.removeValue(forKey: surfaceID)
    agentDetectionPresenceBySurface.removeValue(forKey: surfaceID)
    lastWorkingAtBySurface.removeValue(forKey: surfaceID)
    lastAgentDetectionDiagnosticsBySurface.removeValue(forKey: surfaceID)
    lastAgentScreenScanBySurface.removeValue(forKey: surfaceID)
    if surfaceAgentStates[surfaceID]?.detectedAgent == nil {
      surfaceAgentStates.removeValue(forKey: surfaceID)
    }
  }

  func detectAgentState(for view: GhosttySurfaceView, tabId: TerminalTabID) async -> Bool {
    let surfaceID = view.id
    let childPID = view.bridge.childPID()
    let processGroupID = view.bridge.foregroundProcessGroupID()
    let job = await AgentProcessProbe.shared.foregroundJob(processGroupID: processGroupID, childPID: childPID)
    guard surfaces[surfaceID] != nil else { return false }

    let identified = job.flatMap { identifyAgentInJob($0) }
    let probedAgent = identified?.agent

    var presence = agentDetectionPresenceBySurface[surfaceID] ?? AgentDetectionPresence()
    let agent = presence.update(detectedAgent: probedAgent)
    agentDetectionPresenceBySurface[surfaceID] = presence

    guard let agent else {
      // Only log the moment we lose a previously detected agent; pre-agent
      // shells churn process lists every command and would otherwise spam.
      if surfaceAgentStates[surfaceID]?.detectedAgent != nil {
        logAgentDetectionDiagnostic(
          surfaceID: surfaceID,
          diagnostic: AgentDetectionDiagnostic(
            tabId: tabId,
            childPID: childPID,
            processGroupID: processGroupID,
            job: job,
            identified: identified,
            retainedAgent: nil,
            raw: nil,
            stabilized: nil
          )
        )
      }
      removeAgentEntryIfNeeded(surfaceID: surfaceID)
      return false
    }

    let now = Date()
    let previous = surfaceAgentStates[surfaceID] ?? PaneAgentState(lastChangedAt: now)
    let activeText = view.bridge.readActiveText() ?? ""
    // Reuse the previous scan while the screen and detected agent are unchanged.
    // A live-but-idle agent is polled every 300 ms and `detectState` re-splits,
    // lowercases, and scans the whole screen each time; skipping that for
    // identical text is the bulk of steady-state detection cost. Time-based
    // stabilization below still runs every tick, so working→idle decay is
    // unaffected.
    let raw = cachedRawState(forSurfaceID: surfaceID, agent: agent, text: activeText)
    guard surfaces[surfaceID] != nil else { return false }

    var lastWorkingAt = lastWorkingAtBySurface[surfaceID]
    let stabilized = stabilizeAgentState(
      agent: agent,
      previous: previous.state,
      raw: raw,
      now: now,
      lastWorkingAt: &lastWorkingAt
    )
    lastWorkingAtBySurface[surfaceID] = lastWorkingAt

    let isForeground = isSelected() && isFocusedSurface(surfaceID)
    let becameIdleFromActive =
      (previous.state == .working || previous.state == .blocked)
      && stabilized == .idle
    let seen: Bool
    if isForeground || stabilized == .blocked {
      seen = true
    } else if becameIdleFromActive {
      seen = false
    } else {
      seen = previous.seen
    }
    let iconLookupToken = identified?.iconLookupToken ?? previous.iconLookupToken ?? agent.iconLookupToken
    let workingDirectory = activeAgentWorkingDirectory(surfaceID: surfaceID)
    let (session, sessionMissStreak) = await resolveRetainedSession(
      identified: identified,
      previous: previous,
      workingDirectory: workingDirectory,
      activeText: activeText,
      configRoot: launchProfilesBySurface[surfaceID]?.configRoot(forDetected: agent)
    )
    // Re-check after the suspension: the pane may have been closed and its
    // agent state cleaned up while the resolver was doing file inspection;
    // writing below would resurrect a ghost Active Agents entry.
    guard surfaces[surfaceID] != nil else { return false }
    let launchObservation = resolvedLaunchObservation(identified: identified, previous: previous)
    let lastChangedAt = (previous.detectedAgent != agent || previous.state != stabilized) ? now : previous.lastChangedAt
    var next = PaneAgentState(
      detectedAgent: agent,
      // Presence holds keep the last known pid so a probe gap does not flap
      // the session to nil and back (the resolver re-binds on the next hit).
      agentProcessID: identified?.process.pid ?? previous.agentProcessID,
      launchObservation: launchObservation,
      session: session,
      iconLookupToken: iconLookupToken,
      fallbackState: raw,
      state: stabilized,
      seen: seen,
      lastChangedAt: lastChangedAt
    )
    next.sessionMissStreak = sessionMissStreak
    // Limit logging to meaningful transitions - agent identity or
    // stabilized state changes. Raw oscillation and `seen` flips are
    // routine and would otherwise dominate the log stream.
    if previous.detectedAgent != agent || previous.state != stabilized {
      logAgentDetectionDiagnostic(
        surfaceID: surfaceID,
        diagnostic: AgentDetectionDiagnostic(
          tabId: tabId,
          childPID: childPID,
          processGroupID: processGroupID,
          job: job,
          identified: identified,
          retainedAgent: agent,
          raw: raw,
          stabilized: stabilized
        )
      )
    }
    guard next != previous else { return true }
    surfaceAgentStates[surfaceID] = next
    updateTabAgentBusyState(for: tabId)
    emitAgentEntry(surfaceID: surfaceID, tabId: tabId, state: next)
    return true
  }

  /// Resolves the raw agent state for `text`, reusing `cache` when it already
  /// holds a scan for the same `agent` and identical `text`. Returns the raw
  /// state and the scan to store back for the next call.
  ///
  /// `detectState` is a `nonisolated` pure function of the screen, so reusing
  /// its result for identical input is exactly equivalent to recomputing it.
  /// It runs inline (no `Task.detached`): the detached hop bought only allocator
  /// churn — over a long session each tick left a task stack + closure capture
  /// that never reached ARC, adding up to hundreds of MB of unreferenced
  /// allocations.
  nonisolated static func resolveRawState(
    agent: DetectedAgent,
    text: String,
    cache: AgentScreenScan?
  ) -> (raw: AgentRawState, scan: AgentScreenScan) {
    if let cache, cache.agent == agent, cache.text == text {
      return (cache.raw, cache)
    }
    let raw = agent.detectState(in: text)
    return (raw, AgentScreenScan(agent: agent, text: text, raw: raw))
  }

  /// Instance wrapper over `resolveRawState` that reads and writes the per-surface
  /// memo, keeping `detectAgentState` to a single line at the call site.
  private func cachedRawState(forSurfaceID surfaceID: UUID, agent: DetectedAgent, text: String) -> AgentRawState {
    let (raw, scan) = Self.resolveRawState(agent: agent, text: text, cache: lastAgentScreenScanBySurface[surfaceID])
    lastAgentScreenScanBySurface[surfaceID] = scan
    return raw
  }

  private func resolvedLaunchObservation(
    identified: IdentifiedAgentProcess?,
    previous: PaneAgentState
  ) -> AgentLaunchObservation? {
    let observed = identified.flatMap { identified in
      identified.process.arguments.map {
        AgentRuntimeAdapterRegistry.observe(agent: identified.agent, arguments: $0)
      }
    }
    return PaneAgentState.retainedLaunchObservation(
      observed: observed,
      previous: previous,
      identifiedPID: identified?.process.pid
    )
  }

  private func resolveRetainedSession(
    identified: IdentifiedAgentProcess?,
    previous: PaneAgentState,
    workingDirectory: URL?,
    activeText: String,
    configRoot: URL?
  ) async -> (session: AgentSession?, missStreak: Int) {
    var resolution = AgentSessionResolution(session: nil, isFresh: false)
    if let identified {
      resolution = await AgentSessionResolver.shared.resolve(
        identified: identified,
        workingDirectory: workingDirectory,
        activeText: activeText,
        configRoot: configRoot
      )
    }
    return PaneAgentState.retainedSession(
      resolved: resolution.session,
      isFresh: resolution.isFresh,
      previous: previous,
      identifiedPID: identified?.process.pid
    )
  }

  func markAgentSeen(surfaceID: UUID) {
    guard var state = surfaceAgentStates[surfaceID], !state.seen else { return }
    state.seen = true
    state.lastChangedAt = Date()
    surfaceAgentStates[surfaceID] = state
    guard let tabId = tabId(containing: surfaceID) else { return }
    emitAgentEntry(surfaceID: surfaceID, tabId: tabId, state: state)
  }

  func removeAgentEntryIfNeeded(surfaceID: UUID) {
    guard surfaceAgentStates[surfaceID]?.detectedAgent != nil else { return }
    surfaceAgentStates[surfaceID] = PaneAgentState(lastChangedAt: Date())
    lastWorkingAtBySurface.removeValue(forKey: surfaceID)
    lastEmittedAgentEntriesBySurface.removeValue(forKey: surfaceID)
    // The launch identity lives exactly as long as the launched agent
    // (docs-ai 053/006): once the pane is a bare shell again, a manually
    // started agent is the user's own — default home, default account — and
    // must not wear the profile's name or config root.
    launchProfilesBySurface.removeValue(forKey: surfaceID)
    lastAgentEntryEmitAtBySurface.removeValue(forKey: surfaceID)
    pendingAgentEntryBySurface.removeValue(forKey: surfaceID)
    onAgentEntryRemoved?(surfaceID)
    if let tabId = tabId(containing: surfaceID) {
      updateTabAgentBusyState(for: tabId)
    }
  }

  /// Recompute `tabAgentBusyById[tabId]` from the stabilized state of every
  /// surface in the tab, emitting a task-status change only when the aggregate
  /// flips. Driven by `detectAgentState` (state change), agent release, and
  /// surface teardown so the sidebar/`prowl list` running indicator tracks agent
  /// activity. Uses `displayState` (post-stabilization) so the 3 s working-hold
  /// absorbs raw oscillation; `emitTaskStatusIfChanged` dedupes emissions.
  func updateTabAgentBusyState(for tabId: TerminalTabID) {
    let surfaceIDs = trees[tabId]?.leaves().map(\.id) ?? []
    let isBusy = surfaceIDs.contains { surfaceAgentStates[$0]?.isBusy == true }
    let isBlocked = surfaceIDs.contains { surfaceAgentStates[$0]?.isBlocked == true }
    // Blocked is tracked even when `isBusy` is unchanged: working → blocked
    // leaves the aggregate busy, and that transition is exactly when the
    // sidebar must swap the spinner for the attention affordance. The view
    // observes `tabAgentBlockedById` directly, so no task-status event is
    // needed to redraw it.
    if (tabAgentBlockedById[tabId] ?? false) != isBlocked {
      tabAgentBlockedById[tabId] = isBlocked
    }
    guard (tabAgentBusyById[tabId] ?? false) != isBusy else { return }
    tabAgentBusyById[tabId] = isBusy
    emitTaskStatusIfChanged()
  }

  /// Re-emit Active Agents entries for every pane in `tabId` so the panel picks
  /// up a fresh title snapshot. Title changes (OSC-2, focus sync, manual
  /// rename) don't move agent detection state, so without this nudge the
  /// subtitle only refreshes on the next agent state transition. Used when the
  /// tab's display title changes, since it is every pane's title fallback.
  func refreshAgentEntriesForTitleChange(in tabId: TerminalTabID) {
    let surfaceIDs = trees[tabId]?.leaves().map(\.id) ?? []
    for surfaceID in surfaceIDs {
      refreshAgentEntryForTitleChange(surfaceID: surfaceID, in: tabId)
    }
  }

  /// Lands tab titles held back by coalescing and refreshes the Active Agents
  /// entries that follow them — the same refresh a title written directly through
  /// `updateTitle` triggers, so the two paths cannot drift.
  ///
  /// The manager's clock-driven trailing flush uses the same refresh path. This
  /// synchronous seam lets callers and tests force a flush at an explicit date.
  @discardableResult
  func flushCoalescedTabTitles(now: Date = Date()) -> [TerminalTabID] {
    let flushed = tabManager.flushPendingTitles(now: now)
    for tabID in flushed {
      refreshAgentEntriesForTitleChange(in: tabID)
    }
    return flushed
  }

  /// Single-pane variant for a surface whose own title changed without moving
  /// the tab title (e.g. an unfocused split's OSC-2 update).
  func refreshAgentEntryForTitleChange(surfaceID: UUID, in tabId: TerminalTabID) {
    guard let state = surfaceAgentStates[surfaceID],
      state.detectedAgent != nil,
      state.state != .unknown
    else { return }
    emitAgentEntry(surfaceID: surfaceID, tabId: tabId, state: state)
  }

  /// Minimum spacing between emissions whose only difference is the pane title.
  /// Agent TUIs animate a spinner glyph into the terminal title at roughly 10 Hz;
  /// forwarding each frame mutates `ActiveAgentsFeature.State.entries` and dirties
  /// the SwiftUI graph for a change no one can perceive. One second keeps titles
  /// feeling live while cutting those invalidations by an order of magnitude.
  static let agentEntryTitleCoalescingInterval: TimeInterval = 1

  func emitAgentEntry(
    surfaceID: UUID,
    tabId: TerminalTabID,
    state: PaneAgentState,
    now: Date = Date()
  ) {
    guard let entry = activeAgentEntry(surfaceID: surfaceID, tabId: tabId, state: state) else {
      lastEmittedAgentEntriesBySurface.removeValue(forKey: surfaceID)
      lastAgentEntryEmitAtBySurface.removeValue(forKey: surfaceID)
      pendingAgentEntryBySurface.removeValue(forKey: surfaceID)
      onAgentEntryRemoved?(surfaceID)
      return
    }
    if let previous = lastEmittedAgentEntriesBySurface[surfaceID] {
      // `rawState` flickers every poll while an agent animates and drives no UI,
      // so it never justifies an emission on its own.
      if previous.equalsIgnoringRawState(entry) {
        // A title sequence can return to the value the consumer already displays before the
        // interval ends. Any withheld intermediate frame is obsolete at that point.
        pendingAgentEntryBySurface.removeValue(forKey: surfaceID)
        return
      }
      // Only the animated title moved. Hold it back until the interval elapses;
      // the suppressed entry is not recorded, so the next emission carries the
      // title as of that moment rather than a stale frame.
      if previous.equalsIgnoringRawStateAndPaneTitle(entry),
        let lastEmitAt = lastAgentEntryEmitAtBySurface[surfaceID],
        now.timeIntervalSince(lastEmitAt) < Self.agentEntryTitleCoalescingInterval
      {
        pendingAgentEntryBySurface[surfaceID] = entry
        return
      }
    }
    pendingAgentEntryBySurface.removeValue(forKey: surfaceID)
    lastEmittedAgentEntriesBySurface[surfaceID] = entry
    lastAgentEntryEmitAtBySurface[surfaceID] = now
    onAgentEntryChanged?(entry)
  }

  /// Emits a title-only entry that coalescing held back, once the interval has
  /// passed. Driven by the detection poll rather than a timer, so a spinner that
  /// stops mid-window still settles on its final title within one poll.
  func flushPendingAgentEntry(surfaceID: UUID, now: Date = Date()) {
    guard let pending = pendingAgentEntryBySurface[surfaceID],
      let lastEmitAt = lastAgentEntryEmitAtBySurface[surfaceID],
      now.timeIntervalSince(lastEmitAt) >= Self.agentEntryTitleCoalescingInterval
    else { return }
    pendingAgentEntryBySurface.removeValue(forKey: surfaceID)
    lastEmittedAgentEntriesBySurface[surfaceID] = pending
    lastAgentEntryEmitAtBySurface[surfaceID] = now
    onAgentEntryChanged?(pending)
  }

  func activeAgentEntry(surfaceID: UUID, tabId: TerminalTabID, state: PaneAgentState) -> ActiveAgentEntry? {
    guard let agent = state.detectedAgent, state.state != .unknown else { return nil }
    let paneIDs = trees[tabId]?.leaves().map(\.id) ?? []
    let paneIndex = paneIDs.firstIndex(of: surfaceID).map { $0 + 1 } ?? 1
    let tabTitle = tabManager.tabs.first(where: { $0.id == tabId })?.displayTitle ?? "?"
    let workingDirectory = activeAgentWorkingDirectory(surfaceID: surfaceID)
    return ActiveAgentEntry(
      id: surfaceID,
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      workingDirectory: workingDirectory,
      tabID: tabId,
      paneTitle: paneTitle(surfaceID: surfaceID, fallbackTabTitle: tabTitle),
      surfaceID: surfaceID,
      paneIndex: paneIndex,
      iconLookupToken: state.iconLookupToken ?? agent.iconLookupToken,
      agent: agent,
      session: state.session,
      rawState: state.fallbackState,
      displayState: state.displayState,
      lastChangedAt: state.lastChangedAt,
      launchProfileName: launchProfileName(surfaceID: surfaceID, detected: agent)
    )
  }

  /// Runtime-gated like `SurfaceLaunchProfile.configRoot(forDetected:)`: after
  /// the launched agent exits, a manually started *different* agent in the
  /// same pane must not wear the old profile's name (docs-ai 053/005).
  func launchProfileName(surfaceID: UUID, detected agent: DetectedAgent) -> String? {
    guard let profile = launchProfilesBySurface[surfaceID], profile.runtime.agent == agent else {
      return nil
    }
    return profile.name
  }

  func activeAgentWorkingDirectory(surfaceID: UUID) -> URL? {
    guard let surface = surfaces[surfaceID] else { return nil }
    // This can run while handling Ghostty callbacks, so use cached Swift state instead of
    // re-entering Ghostty for inherited surface config.
    if let pwd = surface.bridge.state.pwd?.trimmingCharacters(in: .whitespacesAndNewlines),
      !pwd.isEmpty
    {
      return URL(fileURLWithPath: pwd, isDirectory: true)
    }
    return surface.launchWorkingDirectory ?? worktree.workingDirectory
  }

  func cleanupAgentDetectionState(forSurfaceId surfaceId: UUID) {
    agentDetectionTasks[surfaceId]?.cancel()
    agentDetectionTasks.removeValue(forKey: surfaceId)
    agentDetectionSchedules.removeValue(forKey: surfaceId)
    surfaceAgentStates.removeValue(forKey: surfaceId)
    agentDetectionPresenceBySurface.removeValue(forKey: surfaceId)
    lastWorkingAtBySurface.removeValue(forKey: surfaceId)
    lastAgentDetectionDiagnosticsBySurface.removeValue(forKey: surfaceId)
    lastAgentScreenScanBySurface.removeValue(forKey: surfaceId)
    lastEmittedAgentEntriesBySurface.removeValue(forKey: surfaceId)
    lastAgentEntryEmitAtBySurface.removeValue(forKey: surfaceId)
    pendingAgentEntryBySurface.removeValue(forKey: surfaceId)
    onAgentEntryRemoved?(surfaceId)
  }

  func cleanupAllAgentDetectionState() {
    for task in agentDetectionTasks.values {
      task.cancel()
    }
    let removedIDs = Array(surfaceAgentStates.keys)
    agentDetectionTasks.removeAll()
    agentDetectionSchedules.removeAll()
    surfaceAgentStates.removeAll()
    agentDetectionPresenceBySurface.removeAll()
    lastWorkingAtBySurface.removeAll()
    lastAgentDetectionDiagnosticsBySurface.removeAll()
    lastAgentScreenScanBySurface.removeAll()
    lastEmittedAgentEntriesBySurface.removeAll()
    lastAgentEntryEmitAtBySurface.removeAll()
    pendingAgentEntryBySurface.removeAll()
    for id in removedIDs {
      onAgentEntryRemoved?(id)
    }
  }

  func agentDetectionDiagnosticMessage(_ diagnostic: AgentDetectionDiagnostic) -> String {
    let processSummary =
      diagnostic.job?.processes
      .map { "\($0.pid):\($0.argv0 ?? $0.name)" }
      .joined(separator: ",") ?? "none"
    return [
      "tab=\(diagnostic.tabId.rawValue.uuidString.prefix(8))",
      "childPID=\(diagnostic.childPID.map(String.init) ?? "nil")",
      "ptyPGID=\(diagnostic.processGroupID.map(String.init) ?? "nil")",
      "fgPGID=\(diagnostic.job.map { String($0.processGroupID) } ?? "nil")",
      "processes=\(processSummary)",
      "identified=\(diagnostic.identified.map { "\($0.agent.rawValue)(\($0.name))" } ?? "nil")",
      "retained=\(diagnostic.retainedAgent?.rawValue ?? "nil")",
      "raw=\(diagnostic.raw?.rawValue ?? "nil")",
      "state=\(diagnostic.stabilized?.rawValue ?? "nil")",
    ].joined(separator: " ")
  }

  func logAgentDetectionDiagnostic(surfaceID: UUID, diagnostic: AgentDetectionDiagnostic) {
    #if DEBUG
      let message = agentDetectionDiagnosticMessage(diagnostic)
      guard lastAgentDetectionDiagnosticsBySurface[surfaceID] != message else { return }
      lastAgentDetectionDiagnosticsBySurface[surfaceID] = message
      terminalStateLogger.debug(
        "agent detection worktree=\(worktree.name) surface=\(surfaceID.uuidString.prefix(8)) \(message)"
      )
    #endif
  }
}
