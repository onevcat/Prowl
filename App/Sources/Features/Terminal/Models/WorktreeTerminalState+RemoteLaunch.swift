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

  /// Whether a local "command finished" (OSC 133) completes a command in this pane. In a
  /// remote pane, it does not while its `ssh` session lasts: it is the `ssh` itself ending,
  /// or a remote shell's own OSC 133 passing through. After the `ssh` ended, the pane is a
  /// local shell, and its commands complete as in any pane. A pane whose `ssh` no probe saw
  /// takes its first finish for the `ssh`.
  func remoteLaunchTakesCommandFinished(surfaceID: UUID) -> Bool {
    guard var origin = remoteLaunchOriginBySurface[surfaceID], !origin.sessionEnded else { return true }
    if let ssh = origin.ssh, isProcessAlive(ssh) { return false }
    origin.sessionEnded = true
    remoteLaunchOriginBySurface[surfaceID] = origin
    return false
  }

  /// The pane's origin while its own `ssh` is in the foreground. The first `ssh` that a
  /// probe sees is the pane's; once it leaves the foreground the session has ended, and a
  /// later `ssh` in the pane is the user's own (the L0 path, with its consent).
  func activeRemoteLaunchOrigin(surfaceID: UUID, foregroundSSH ssh: LocalProcessGeneration?) -> RemoteLaunchOrigin? {
    guard var origin = remoteLaunchOriginBySurface[surfaceID], !origin.sessionEnded else { return nil }
    switch (origin.ssh, ssh) {
    case (nil, nil):
      return nil
    case (nil, let ssh?):
      origin.ssh = ssh
    case (let bound?, let ssh?) where bound == ssh:
      return origin
    case (.some, _):
      origin.sessionEnded = true
    }
    remoteLaunchOriginBySurface[surfaceID] = origin
    return origin.sessionEnded ? nil : origin
  }

  /// The label of a remote pane's host: the profile alias for a pane that Prowl opened.
  func remoteHostAlias(surfaceID: UUID) -> String? {
    guard let origin = remoteLaunchOriginBySurface[surfaceID], !origin.sessionEnded else { return nil }
    return origin.alias
  }

  /// A remote pane whose launcher is still being staged: it has no surface yet, so a close
  /// frees it instead of keeping it for Undo.
  func isAwaitingRemoteLaunch(_ surfaceID: UUID) -> Bool {
    remoteLaunchTasksBySurface[surfaceID] != nil
  }

  func forgetRemoteLaunch(surfaceID: UUID) {
    remoteLaunchTasksBySurface.removeValue(forKey: surfaceID)?.cancel()
    remoteLaunchOriginBySurface.removeValue(forKey: surfaceID)
  }

  private func isProcessAlive(_ process: LocalProcessGeneration) -> Bool {
    if let alive = processIsAliveForTesting { return alive(process) }
    return ProcessDetection.processStartDate(pid: process.pid) == process.startedAt
  }
}
