import AppKit
import Foundation

/// Remote panes (docs-ai 084 C3b): a remote folder's tab is a local pane whose shell types
/// `ssh -t <recipe> -- exec sh <launcher>` once the launcher is staged on the host. The
/// pane keeps a `RemoteLaunchOrigin`: the agent tracker uses its stored recipe without the
/// consent panel, labels show the profile alias, and the launch's completion marker is the
/// only completion of its first command.
extension WorktreeTerminalState {
  var remoteTerminalStager: RemoteTerminalStager {
    remoteTerminalStagerForTesting ?? .live
  }

  /// The launch of a remote pane: the folder's paths and the pane id on the host.
  func remoteLaunch(surfaceID: UUID, workingDirectory: String, firstCommand: String?) -> RemoteLaunch {
    RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: workingDirectory,
      environment: [
        RemoteLaunchVariable(name: "PROWL_WORKTREE_PATH", value: worktree.location.path),
        RemoteLaunchVariable(name: "PROWL_ROOT_PATH", value: worktree.repositoryLocation.path),
        RemoteLaunchVariable(name: GhosttySurfaceView.remotePaneIdentityEnvironmentKey, value: surfaceID.uuidString),
      ],
      firstCommand: firstCommand)
  }

  /// A remote pane's local working directory: the recipe's, so relative `-F` and `-i`
  /// options resolve as when the host was added.
  static func localDirectory(for profile: HostProfile) -> URL {
    profile.recipe.workingDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  /// How long a split waits for a fresh snapshot of its anchor's directory.
  static let splitDirectoryTimeout: Duration = .seconds(1)

  /// Where a remote split starts (C4): `override` (a host path), else where the anchor pane
  /// is on the host now (a fresh probe, then the last known one), else the folder.
  func remoteSplitDirectory(anchorSurfaceID: UUID, override: URL?) async -> String {
    if let override { return Self.hostPath(override.path(percentEncoded: false)) }
    if remoteHostAlias(surfaceID: anchorSurfaceID) != nil, let tracker = remotePaneTrackers[anchorSurfaceID],
      let directory = await tracker.refreshedWorkingDirectory(
        timeout: Self.splitDirectoryTimeout, clock: remoteLaunchClock)
    {
      return directory
    }
    return worktree.location.path
  }

  /// Stages `launch` on the host, then types the `ssh` line into the deferred pane and
  /// creates its surface. A failure closes the tab (nothing ran in it) and tells the user.
  /// A launch that carries the pending setup script (`consumesSetupScript`) consumes it only
  /// once the launcher is staged; otherwise it stays pending for the next tab.
  /// A `resolveWorkingDirectory` (a split's) decides the launch's directory before staging.
  func startRemoteLaunch(
    _ launch: RemoteLaunch, profile: HostProfile, surfaceID: UUID, tabID: TerminalTabID, consumesSetupScript: Bool,
    resolveWorkingDirectory: (@MainActor () async -> String)? = nil
  ) {
    remoteLaunchOriginBySurface[surfaceID] = RemoteLaunchOrigin(
      hostProfileID: profile.id, alias: profile.alias, recipe: profile.recipe, nonce: launch.nonce,
      hasFirstCommand: launch.firstCommand != nil, launchedAt: Date())
    let stager = remoteTerminalStager
    remoteLaunchTasksBySurface[surfaceID] = Task { [weak self] in
      var launch = launch
      if let resolveWorkingDirectory {
        launch.workingDirectory = await resolveWorkingDirectory()
        // The pane was closed while its directory was resolved: stage nothing on the host.
        guard !Task.isCancelled else { return }
      }
      let staged: Result<String, any Error>
      do {
        staged = .success(try await stager.stage(profile, launch))
      } catch {
        staged = .failure(error)
      }
      self?.finishRemoteLaunch(
        staged, profile: profile,
        pane: StagedRemotePane(surfaceID: surfaceID, tabID: tabID, nonce: launch.nonce),
        consumesSetupScript: consumesSetupScript)
    }
  }

  /// The pane that a staging result belongs to.
  private struct StagedRemotePane {
    let surfaceID: UUID
    let tabID: TerminalTabID
    let nonce: String
  }

  private func finishRemoteLaunch(
    _ staged: Result<String, any Error>, profile: HostProfile, pane: StagedRemotePane, consumesSetupScript: Bool
  ) {
    let (surfaceID, tabID, nonce) = (pane.surfaceID, pane.tabID, pane.nonce)
    remoteLaunchTasksBySurface.removeValue(forKey: surfaceID)
    // The tab was closed while the launcher was staged: its setup script never ran.
    guard let view = surfaces[surfaceID], remoteLaunchOriginBySurface[surfaceID]?.nonce == nonce else {
      if consumesSetupScript { pendingSetupScript = true }
      return
    }
    let failure: any Error
    do {
      view.setInitialInput(try RemoteTerminalLine.typed(recipe: profile.recipe, launcherPath: try staged.get()))
      if view.armSurfaceCreation() {
        remoteLaunchOriginBySurface[surfaceID]?.launchedAt = Date()
        if consumesSetupScript { onSetupScriptConsumed?() }
        // The pane took focus while it had no surface, which Ghostty never saw.
        if view.window?.firstResponder === view { view.focusDidChange(true) }
        wakeAgentDetection(for: view, tabId: tabID)
        return
      }
      failure = RemoteLauncher.StagingError.invalidLaunch
    } catch {
      failure = error
    }
    terminalStateLogger.warning("Remote pane on \(profile.alias) did not start: \(failure.localizedDescription)")
    if consumesSetupScript { pendingSetupScript = true }
    // Nothing ran in the pane: a split goes alone, a tab with its only pane.
    if (trees[tabID]?.leaves().count ?? 0) > 1 {
      _ = closeSurface(id: surfaceID, confirmation: .skip, retainForUndo: false)
    } else {
      _ = closeTab(tabID, confirmation: .skip, retainForUndo: false)
    }
    onRemoteTerminalFailed?(
      String(localized: "The terminal on \(profile.alias) did not start: \(failure.localizedDescription)"))
  }

  /// Consumes an OSC 7501 report whose id is a launch marker (`prowl-launch/…`): such a
  /// report is never a program status. The marker of the pane's own launch completes its
  /// first command once; any other is ignored.
  func handleRemoteLaunchMarker(_ report: GhosttyProgramStatusReport, surfaceID: UUID, now: Date = Date()) -> Bool {
    guard report.id.hasPrefix(RemoteLauncher.markerIDPrefix + "/") else { return false }
    guard let completion = RemoteLauncher.completion(fromMarkerID: report.id),
      var origin = remoteLaunchOriginBySurface[surfaceID], origin.nonce == completion.nonce, origin.hasFirstCommand,
      !origin.completed
    else { return true }
    origin.completed = true
    remoteLaunchOriginBySurface[surfaceID] = origin
    let durationNs = UInt64(max(0, now.timeIntervalSince(origin.launchedAt)) * 1_000_000_000)
    let exitCode = Int(completion.exitStatus)
    resumeCommandFinishedWaiter(exitCode: exitCode, durationNs: durationNs, surfaceId: surfaceID)
    completeCommand(exitCode: exitCode, durationNs: durationNs, surfaceId: surfaceID)
    return true
  }

  /// Whether CLI waiters wait for the launch marker: while the pane's first command runs on
  /// the host, a local "command finished" is never its end (C3c).
  func remoteLaunchHoldsWaiters(surfaceID: UUID) -> Bool {
    guard let origin = remoteLaunchOriginBySurface[surfaceID] else { return false }
    return origin.hasFirstCommand && !origin.completed
  }

  /// Whether a local "command finished" (OSC 133) completes a command in this pane (the
  /// custom command toast, Close on Success, the long-command notification). In a remote
  /// pane, it does not while its `ssh` session lasts: it is the
  /// `ssh` itself ending, or a remote shell's own OSC 133 passing through. After the `ssh`
  /// ended, the pane is a local shell, and its commands complete as in any pane.
  func remoteLaunchTakesCommandFinished(surfaceID: UUID) -> Bool {
    guard var origin = remoteLaunchOriginBySurface[surfaceID] else { return true }
    defer { remoteLaunchOriginBySurface[surfaceID] = origin }
    if origin.sessionEnded {
      if origin.swallowsNextFinish {
        origin.swallowsNextFinish = false
        scheduleAbandonFirstCommand(surfaceID: surfaceID)
        return false
      }
      // A first command still within its marker grace keeps its reactions: a local command
      // that finishes then completes nothing, so it cannot take the script's toast or Close
      // on Success.
      return !origin.hasFirstCommand || origin.completed
    }
    if let ssh = origin.ssh {
      if !isRunning(ssh) {
        origin.sessionEnded = true
        scheduleAbandonFirstCommand(surfaceID: surfaceID)
      }
    } else {
      // No probe saw the `ssh` yet: the next one decides (`activeRemoteLaunchOrigin`).
      origin.unboundFinishSeen = true
    }
    return false
  }

  /// The pane's origin while its own `ssh` is in the foreground: the `ssh` whose arguments
  /// carry the launch's nonce. Once it leaves the foreground, or no `ssh` is in front after a
  /// finish that no bound `ssh` explains, the session has ended, and a later `ssh` in the
  /// pane is the user's own (the L0 path, with its consent).
  func activeRemoteLaunchOrigin(
    surfaceID: UUID, foregroundSSH ssh: (generation: LocalProcessGeneration, arguments: [String])?
  ) -> RemoteLaunchOrigin? {
    guard var origin = remoteLaunchOriginBySurface[surfaceID], !origin.sessionEnded else { return nil }
    defer { remoteLaunchOriginBySurface[surfaceID] = origin }
    if let bound = origin.ssh {
      if ssh?.generation == bound { return origin }
      // The pane's `ssh` left the foreground. When it exited, the local shell's finish for it
      // is still to come, after any marker the `ssh` printed. A suspended one reports none:
      // its first command completes nothing, so no later local finish completes it.
      origin.sessionEnded = true
      origin.swallowsNextFinish = !isRunning(bound)
      if !origin.swallowsNextFinish { abandonFirstCommand(&origin, surfaceID: surfaceID) }
      return nil
    }
    if let ssh, ssh.arguments.contains(where: { $0.contains(origin.nonce) }) {
      origin.ssh = ssh.generation
      origin.unboundFinishSeen = false
      return origin
    }
    // Not started yet, unless a finish came: then the `ssh` ended before any probe saw it.
    if origin.unboundFinishSeen {
      origin.sessionEnded = true
      scheduleAbandonFirstCommand(surfaceID: surfaceID)
    }
    return nil
  }

  /// After the `ssh` ended, a first command still without a marker did not run to its end on
  /// the host (the launcher reports every command that started, C3a). The decision waits
  /// `remoteMarkerGrace` after the finish: a remote shell's own OSC 133 can come just before
  /// the marker, after the `ssh` exited, and the marker must still count. A probe that sees
  /// the `ssh` exit never decides this.
  private func scheduleAbandonFirstCommand(surfaceID: UUID) {
    guard let origin = remoteLaunchOriginBySurface[surfaceID], origin.hasFirstCommand, !origin.completed else {
      return
    }
    let clock = remoteLaunchClock
    Task { [weak self] in
      try? await clock.sleep(for: Self.remoteMarkerGrace)
      guard let self, var origin = self.remoteLaunchOriginBySurface[surfaceID] else { return }
      self.abandonFirstCommand(&origin, surfaceID: surfaceID)
      self.remoteLaunchOriginBySurface[surfaceID] = origin
    }
  }

  static let remoteMarkerGrace: Duration = .seconds(1)

  /// The first command completes nothing: no success toast, no Close on Success, and a CLI
  /// waiter gets no status.
  private func abandonFirstCommand(_ origin: inout RemoteLaunchOrigin, surfaceID: UUID) {
    guard origin.hasFirstCommand, !origin.completed else { return }
    origin.completed = true
    resumeCommandFinishedWaiter(exitCode: nil, durationNs: 0, surfaceId: surfaceID)
    pendingCustomCommands.removeValue(forKey: surfaceID)
    autoCloseSurfaceIds.remove(surfaceID)
  }

  /// The label of a remote pane's host: the profile alias, while the pane's own `ssh` is
  /// the session.
  func remoteHostAlias(surfaceID: UUID) -> String? {
    guard let origin = remoteLaunchOriginBySurface[surfaceID], origin.ssh != nil, !origin.sessionEnded else {
      return nil
    }
    return origin.alias
  }

  /// A remote pane whose launcher is still being staged: it has no surface yet, so a close
  /// frees it instead of keeping it for Undo.
  func isAwaitingRemoteLaunch(_ surfaceID: UUID) -> Bool {
    remoteLaunchTasksBySurface[surfaceID] != nil
  }

  private func isRunning(_ process: LocalProcessGeneration) -> Bool {
    processIsAliveForTesting?(process) ?? process.isRunning
  }

  func forgetRemoteLaunch(surfaceID: UUID) {
    remoteLaunchTasksBySurface.removeValue(forKey: surfaceID)?.cancel()
    remoteLaunchOriginBySurface.removeValue(forKey: surfaceID)
  }
}
