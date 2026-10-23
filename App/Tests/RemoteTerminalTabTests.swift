import ConcurrencyExtras
import Foundation
import GhosttyKit
import IdentifiedCollections
import Testing

@testable import Prowl

/// Remote folder tabs (docs-ai 084 C3b): a local pane that types the `ssh` line once the
/// launcher is staged, its `RemoteLaunchOrigin`, the completion marker, and the local
/// "command finished" of its `ssh`.
@MainActor
struct RemoteTerminalTabTests {
  private static let profile = HostProfile(
    id: RemoteRepositoryFixtures.hostProfileID, alias: "mini",
    recipe: SSHConnectionRecipe(
      destination: "dev@mini", options: ["-p", "2222", "-o", "ProxyJump=jump host"],
      workingDirectory: "/Users/dev/ssh"),
    connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))

  /// What the fake stager saw, and an optional gate that holds the staging.
  private nonisolated final class Staging: Sendable {
    let launches = LockIsolated<[RemoteLaunch]>([])
    let failure: (any Error & Sendable)?
    let gate: AsyncStream<Void>?
    let entered = LockIsolated(false)

    init(failure: (any Error & Sendable)? = nil, gate: AsyncStream<Void>? = nil) {
      self.failure = failure
      self.gate = gate
    }

    func stager(profile: HostProfile?) -> RemoteTerminalStager {
      RemoteTerminalStager(
        profile: { _ in profile },
        stage: { _, launch in
          self.launches.withValue { $0.append(launch) }
          self.entered.setValue(true)
          if let gate = self.gate {
            for await _ in gate { break }
          }
          if let failure = self.failure { throw failure }
          return "/home/dev/.cache/prowl/launch/\(launch.nonce)/launch.sh"
        })
    }
  }

  private func makeState(_ staging: Staging, profile: HostProfile? = Self.profile) -> WorktreeTerminalState {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(), worktree: RemoteRepositoryFixtures.gitRepository().worktrees[0],
      skipsSurfaceCreationForTesting: true)
    state.remoteTerminalStagerForTesting = staging.stager(profile: profile)
    return state
  }

  private func onlySurface(_ state: WorktreeTerminalState, _ tabID: TerminalTabID) throws -> GhosttySurfaceView {
    try #require(state.trees[tabID]?.root?.leftmostLeaf())
  }

  /// The tab opens at once; once the launcher is staged, the pane types the `ssh` line
  /// (the stored recipe, quoted where needed) and starts. The launch exports the host paths
  /// and the pane id; the local pane gets neither host path, and starts in the recipe's
  /// directory. A setup script does not run in a remote folder yet (C3c).
  @Test func aRemoteTabTypesTheSSHLineOnceTheLauncherIsStaged() async throws {
    let staging = Staging()
    let state = makeState(staging)

    let tabID = try #require(state.createTab(setupScript: "echo setup"))
    let surface = try onlySurface(state, tabID)
    await waitUntil { surface.surfaceCreationArmed }

    let launch = try #require(staging.launches.value.first)
    #expect(launch.workingDirectory == "/home/dev/app")
    #expect(launch.firstCommand == nil)
    #expect(
      launch.environment == [
        RemoteLaunchVariable(name: "PROWL_WORKTREE_PATH", value: "/home/dev/app"),
        RemoteLaunchVariable(name: "PROWL_ROOT_PATH", value: "/home/dev/app"),
        RemoteLaunchVariable(name: "LC_PROWL_PANE", value: surface.id.uuidString),
      ])
    #expect(
      surface.initialInputForTesting
        == " /usr/bin/ssh -t -p 2222 -o 'ProxyJump=jump host' -- dev@mini exec sh"
        + " /home/dev/.cache/prowl/launch/\(launch.nonce)/launch.sh\n")
    #expect(surface.launchWorkingDirectory?.path(percentEncoded: false) == "/Users/dev/ssh/")
    #expect(surface.launchEnvironment["PROWL_WORKTREE_PATH"] == nil)
    #expect(surface.launchEnvironment["PROWL_ROOT_PATH"] == nil)
    let origin = try #require(state.remoteLaunchOriginBySurface[surface.id])
    #expect(origin.alias == "mini")
    #expect(origin.recipe == Self.profile.recipe)
    #expect(origin.nonce == launch.nonce)
    #expect(!origin.hasFirstCommand)
  }

  /// A staging failure closes the tab, in which nothing ran, and tells the user why.
  @Test func aRemoteTabThatCannotStageClosesAndTellsTheUser() async throws {
    let state = makeState(Staging(failure: RemoteRepositoryHostError.timedOut))
    var messages: [String] = []
    state.onRemoteTerminalFailed = { messages.append($0) }

    _ = try #require(state.createTab())
    await waitUntil { !messages.isEmpty }

    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.remoteLaunchOriginBySurface.isEmpty)
    #expect(messages == ["The terminal on mini did not start: The remote host did not answer in time."])
  }

  /// A tab closed while its launcher is staged never starts, and Undo has nothing to bring
  /// back: the pane never ran.
  @Test func aRemoteTabClosedWhileStagingNeverStarts() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let staging = Staging(gate: gate)
    let state = makeState(staging)
    var recorded = false
    state.onCloseRecorded = { _ in recorded = true }

    let tabID = try #require(state.createTab())
    let surface = try onlySurface(state, tabID)
    await waitUntil { staging.entered.value }
    #expect(state.closeTab(tabID, confirmation: .skip))
    release.yield(())
    release.finish()
    for _ in 0..<50 { await Task.yield() }

    #expect(!surface.surfaceCreationArmed)
    #expect(surface.initialInputForTesting == nil)
    #expect(!recorded)
    #expect(state.remoteLaunchTasksBySurface.isEmpty)
  }

  /// A missing host profile opens no tab and tells the user.
  @Test func aRemoteTabWithoutItsHostProfileTellsTheUser() {
    let state = makeState(Staging(), profile: nil)
    var messages: [String] = []
    state.onRemoteTerminalFailed = { messages.append($0) }

    #expect(state.createTab() == nil)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(messages.count == 1)
  }

  /// A script and a split in a remote folder would be local shells: refused until C3c and
  /// C4.
  @Test func aRemoteFolderRefusesAScriptAndASplit() throws {
    let staging = Staging()
    let state = makeState(staging)

    #expect(state.runScript("echo run") == nil)
    #expect(state.tabManager.tabs.isEmpty)
    let tabID = try #require(state.createTab())
    let surface = try onlySurface(state, tabID)
    #expect(state.createSplit(of: surface.id, direction: .right, initialInput: nil) == .failure(.remoteFolder))
    #expect(state.trees[tabID]?.leaves().count == 1)
  }

  // MARK: - Completion

  private func startedRemotePane(
    _ state: WorktreeTerminalState, hasFirstCommand: Bool
  ) async throws -> (surface: GhosttySurfaceView, nonce: String) {
    let tabID = try #require(state.createTab())
    let surface = try onlySurface(state, tabID)
    await waitUntil { surface.surfaceCreationArmed }
    let origin = try #require(state.remoteLaunchOriginBySurface[surface.id])
    state.remoteLaunchOriginBySurface[surface.id] = RemoteLaunchOrigin(
      hostProfileID: origin.hostProfileID, alias: origin.alias, recipe: origin.recipe, nonce: origin.nonce,
      hasFirstCommand: hasFirstCommand, launchedAt: origin.launchedAt)
    return (surface, origin.nonce)
  }

  private func marker(_ id: String, state: GhosttyProgramStatusReport.State = .done) -> GhosttyProgramStatusReport {
    GhosttyProgramStatusReport(state: state, id: id)
  }

  /// The pane's own marker completes its first command once: the CLI waiter and the custom
  /// command toast get its status. A marker is never a program status.
  @Test(.timeLimit(.minutes(1))) func theLaunchMarkerCompletesTheFirstCommandOnce() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: true)
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }
    state.markSurfaceForCustomCommand(surface.id, name: "Setup")
    let waiter = state.waitForCommandFinished(surfaceID: surface.id)

    state.handleProgramStatus(marker("prowl-launch/\(nonce)/0"), surfaceID: surface.id)
    state.markSurfaceForCustomCommand(surface.id, name: "Again")
    state.handleProgramStatus(marker("prowl-launch/\(nonce)/0"), surfaceID: surface.id)

    var results: [Int?] = []
    for await result in waiter { results.append(result.exitCode) }
    #expect(results == [0])
    #expect(succeeded == ["Setup"])
    #expect(state.programStatusStoresBySurface[surface.id] == nil)
  }

  /// Another launch's marker, a marker for a pane without a first command, a malformed
  /// one and one in a local pane complete nothing, and are not program statuses either.
  @Test func anyOtherLaunchMarkerIsIgnored() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: true)
    let (plain, plainNonce) = try await startedRemotePane(state, hasFirstCommand: false)
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }
    state.markSurfaceForCustomCommand(surface.id, name: "Setup")

    state.handleProgramStatus(marker("prowl-launch/0123456789abcdef/0"), surfaceID: surface.id)
    state.handleProgramStatus(marker("prowl-launch/\(nonce)/x"), surfaceID: surface.id)
    state.handleProgramStatus(marker("prowl-launch/\(plainNonce)/0"), surfaceID: plain.id)
    state.handleProgramStatus(marker("prowl-launch/\(nonce)/0"), surfaceID: UUID())

    #expect(succeeded.isEmpty)
    #expect(state.programStatusStoresBySurface.isEmpty)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.completed == false)
  }

  private static func ssh(_ pid: pid_t, nonce: String?) -> (generation: LocalProcessGeneration, arguments: [String]) {
    let path = "/home/dev/.cache/prowl/launch/\(nonce ?? "user")/launch.sh"
    return (
      LocalProcessGeneration(pid: pid, startedAt: Date(timeIntervalSince1970: 1)),
      nonce == nil ? ["mini"] : ["-t", "--", "dev@mini", "exec", "sh", path]
    )
  }

  /// While the pane's `ssh` runs, a local "command finished" is a remote shell's OSC 133 and
  /// completes nothing; the `ssh`'s own finish completes nothing either. After it, the pane
  /// is a local shell and its commands complete as usual. A CLI waiter resumes on each.
  @Test func theSSHFinishCompletesNothingAndLaterCommandsDo() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: false)
    let ssh = Self.ssh(4_242, nonce: nonce)
    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: ssh)?.ssh == ssh.generation)
    #expect(state.remoteHostAlias(surfaceID: surface.id) == "mini")
    var alive = true
    state.processIsAliveForTesting = { _ in alive }
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }
    state.markSurfaceForCustomCommand(surface.id, name: "Build")

    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)
    alive = false
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)
    #expect(succeeded.isEmpty)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.sessionEnded == true)
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)

    #expect(succeeded == ["Build"])
    // The pane is no longer the remote session: no alias, no origin for a later `ssh`.
    #expect(state.remoteHostAlias(surfaceID: surface.id) == nil)
    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: ssh) == nil)
  }

  /// A CLI waiter resumes on any finish, also the `ssh`'s: a command typed into the host
  /// shell finishes there.
  @Test(.timeLimit(.minutes(1))) func aWaiterResumesInARemotePane() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: false)
    _ = state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: Self.ssh(4_242, nonce: nonce))
    state.processIsAliveForTesting = { _ in true }
    let waiter = state.waitForCommandFinished(surfaceID: surface.id)

    state.handleCommandFinished(exitCode: 3, durationNs: 1, surfaceId: surface.id)

    var results: [Int?] = []
    for await result in waiter { results.append(result.exitCode) }
    #expect(results == [3])
  }

  /// A finish before any probe saw the `ssh`: the next probe decides. The pane's own `ssh`
  /// in front means the finish came from the host; no `ssh` in front means the `ssh` ended.
  @Test func aFinishBeforeTheFirstProbeWaitsForIt() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: false)
    let (ended, _) = try await startedRemotePane(state, hasFirstCommand: false)
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }

    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)
    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: Self.ssh(1, nonce: nonce)) != nil)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.sessionEnded == false)
    #expect(state.remoteHostAlias(surfaceID: surface.id) == "mini")

    state.handleCommandFinished(exitCode: 255, durationNs: 1, surfaceId: ended.id)
    #expect(state.activeRemoteLaunchOrigin(surfaceID: ended.id, foregroundSSH: nil) == nil)
    #expect(state.remoteLaunchOriginBySurface[ended.id]?.sessionEnded == true)
    state.markSurfaceForCustomCommand(ended.id, name: "Build")
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: ended.id)
    #expect(succeeded == ["Build"])
  }

  /// Only the `ssh` that runs the launch is the pane's: an `ssh` the user typed after the
  /// pane's own one never ran is not bound, so it gets no alias and no stored recipe.
  @Test func anSSHWithoutTheNonceIsNotThePanes() async throws {
    let state = makeState(Staging())
    let (surface, _) = try await startedRemotePane(state, hasFirstCommand: false)

    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: Self.ssh(7, nonce: nil)) == nil)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.ssh == nil)
    #expect(state.remoteHostAlias(surfaceID: surface.id) == nil)
  }

  /// A probe that sees the pane's `ssh` gone before the local shell reported its finish:
  /// that finish still completes nothing, and the next one does.
  @Test func theSSHFinishAfterAProbeSawItExitCompletesNothing() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: false)
    let ssh = Self.ssh(4_242, nonce: nonce)
    _ = state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: ssh)
    state.processIsAliveForTesting = { _ in false }
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }

    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: nil) == nil)
    state.markSurfaceForCustomCommand(surface.id, name: "Session")
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)
    state.markSurfaceForCustomCommand(surface.id, name: "Build")
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)

    #expect(succeeded == ["Build"])
  }

  /// A remote folder's tabs are not saved in the layout, and a saved layout is not applied
  /// to one: a restored leaf would be a local shell until C5.
  @Test func aRemoteFolderHasNoSavedLayout() throws {
    let state = makeState(Staging())
    _ = try #require(state.createTab())
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: state.worktree.id, selectedTabID: nil, tabs: [])

    #expect(!state.applyLayoutSnapshot(snapshot))
  }

  // MARK: - The typed line

  @Test func theTypedLineQuotesWhatIsNotSafeAndRefusesWhatNoShellTypesTheSame() throws {
    let path = "/home/dev/.cache/prowl/launch/0123456789abcdef/launch.sh"
    #expect(
      try RemoteTerminalLine.typed(recipe: SSHConnectionRecipe(destination: "mini"), launcherPath: path)
        == " /usr/bin/ssh -t -- mini exec sh \(path)\n")
    #expect(
      try RemoteTerminalLine.typed(
        recipe: SSHConnectionRecipe(destination: "dev@mini", options: ["-F", "it's config", "-o", "SendEnv=A*"]),
        launcherPath: path)
        == " /usr/bin/ssh -t -F 'it'\\''s config' -o 'SendEnv=A*' -- dev@mini exec sh \(path)\n")
    for options in [["-F", #"C:\config"#], ["-o", "User=a\nb"], ["-o", "User=a\u{7f}"]] {
      #expect(throws: RemoteTerminalLine.LineError.untypeable) {
        try RemoteTerminalLine.typed(
          recipe: SSHConnectionRecipe(destination: "mini", options: options), launcherPath: path)
      }
    }
    for launcherPath in ["/home/my dev/launch.sh", "/home/dev/$x/launch.sh", ""] {
      #expect(throws: RemoteTerminalLine.LineError.untypeable) {
        try RemoteTerminalLine.typed(recipe: SSHConnectionRecipe(destination: "mini"), launcherPath: launcherPath)
      }
    }
  }
}
