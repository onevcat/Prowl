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

  /// Stages `launch` on the host, then types the `ssh` line into the deferred pane and
  /// creates its surface. A failure closes the tab (nothing ran in it) and tells the user.
  func startRemoteLaunch(_ launch: RemoteLaunch, profile: HostProfile, surfaceID: UUID, tabID: TerminalTabID) {
    remoteLaunchOriginBySurface[surfaceID] = RemoteLaunchOrigin(
      hostProfileID: profile.id, alias: profile.alias, recipe: profile.recipe, nonce: launch.nonce,
      hasFirstCommand: launch.firstCommand != nil, launchedAt: Date())
    let stager = remoteTerminalStager
    remoteLaunchTasksBySurface[surfaceID] = Task { [weak self] in
      let staged: Result<String, any Error>
      do {
        staged = .success(try await stager.stage(profile, launch))
      } catch {
        staged = .failure(error)
      }
      self?.finishRemoteLaunch(staged, profile: profile, nonce: launch.nonce, surfaceID: surfaceID, tabID: tabID)
    }
  }

  private func finishRemoteLaunch(
    _ staged: Result<String, any Error>, profile: HostProfile, nonce: String, surfaceID: UUID, tabID: TerminalTabID
  ) {
    remoteLaunchTasksBySurface.removeValue(forKey: surfaceID)
    // The tab was closed while the launcher was staged.
    guard let view = surfaces[surfaceID], remoteLaunchOriginBySurface[surfaceID]?.nonce == nonce else { return }
    let failure: any Error
    do {
      view.setInitialInput(try RemoteTerminalLine.typed(recipe: profile.recipe, launcherPath: try staged.get()))
      if view.armSurfaceCreation() {
        // The pane took focus while it had no surface, which Ghostty never saw.
        if view.window?.firstResponder === view { view.focusDidChange(true) }
        wakeAgentDetection(for: view, tabId: tabID)
        return
      }
      failure = RemoteLauncher.StagingError.invalidLaunch
    } catch {
      failure = error
    }
    terminalStateLogger.warning("Remote tab on \(profile.alias) did not start: \(failure.localizedDescription)")
    _ = closeTab(tabID, confirmation: .skip, retainForUndo: false)
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
      guard origin.swallowsNextFinish else { return true }
      origin.swallowsNextFinish = false
      abandonFirstCommand(&origin, surfaceID: surfaceID)
      return false
    }
    if let ssh = origin.ssh {
      if !isRunning(ssh) {
        origin.sessionEnded = true
        abandonFirstCommand(&origin, surfaceID: surfaceID)
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
      // is still to come, after any marker the `ssh` printed; a suspended one reports none.
      origin.sessionEnded = true
      origin.swallowsNextFinish = !isRunning(bound)
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
      abandonFirstCommand(&origin, surfaceID: surfaceID)
    }
    return nil
  }

  /// The `ssh`'s finish has come, in the terminal stream after any marker the `ssh` printed:
  /// a first command without a marker did not run to its end on the host (the launcher
  /// reports every command that started, C3a). It completes nothing, so no success toast
  /// and no Close on Success, and a CLI waiter gets no status. A probe that sees the `ssh`
  /// exit does not decide this: the marker may still be in the stream.
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
