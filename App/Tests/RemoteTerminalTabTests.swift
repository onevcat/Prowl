import Clocks
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
  /// directory. A tab without a script has no first command.
  @Test func aRemoteTabTypesTheSSHLineOnceTheLauncherIsStaged() async throws {
    let staging = Staging()
    let state = makeState(staging)

    let tabID = try #require(state.createTab())
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
        == " /usr/bin/ssh -t \(Self.overrides) -p 2222 -o 'ProxyJump=jump host' -- dev@mini exec sh"
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

  /// A split in a remote folder is a new remote pane (C4): its input is its own launch's
  /// first command, never typed into a local shell; with no known directory of the anchor
  /// on the host, it starts in the folder.
  @Test func aRemoteSplitIsANewRemotePane() async throws {
    let staging = Staging()
    let state = makeState(staging)
    let tabID = try #require(state.createTab())
    let anchor = try onlySurface(state, tabID)
    await waitUntil { anchor.surfaceCreationArmed }

    let splitID = try state.createSplit(of: anchor.id, direction: .right, initialInput: "make watch").get()
    let split = try #require(state.surfaceView(for: splitID))
    await waitUntil { split.surfaceCreationArmed }

    #expect(state.trees[tabID]?.leaves().count == 2)
    let launch = try #require(staging.launches.value.last)
    #expect(staging.launches.value.count == 2)
    #expect(launch.workingDirectory == "/home/dev/app")
    #expect(launch.firstCommand == "make watch\n")
    #expect(launch.environment.contains(RemoteLaunchVariable(name: "LC_PROWL_PANE", value: splitID.uuidString)))
    #expect(split.initialInputForTesting?.hasPrefix(" /usr/bin/ssh -t ") == true)
    #expect(split.initialInputForTesting?.contains("make watch") == false)
    #expect(state.remoteLaunchOriginBySurface[splitID]?.hasFirstCommand == true)
  }

  /// A split that cannot stage closes alone: the tab and its other panes stay.
  @Test func aSplitThatCannotStageClosesAlone() async throws {
    let launches = LockIsolated(0)
    let state = makeState(Staging())
    state.remoteTerminalStagerForTesting = RemoteTerminalStager(
      profile: { _ in Self.profile },
      stage: { _, launch in
        let count = launches.withValue {
          $0 += 1
          return $0
        }
        if count > 1 { throw RemoteRepositoryHostError.timedOut }
        return "/home/dev/.cache/prowl/launch/\(launch.nonce)/launch.sh"
      })
    var messages: [String] = []
    state.onRemoteTerminalFailed = { messages.append($0) }
    let tabID = try #require(state.createTab())
    let anchor = try onlySurface(state, tabID)
    await waitUntil { anchor.surfaceCreationArmed }

    _ = try state.createSplit(of: anchor.id, direction: .right, initialInput: nil).get()
    await waitUntil { !messages.isEmpty }

    #expect(state.tabManager.tabs.map(\.id) == [tabID])
    #expect(state.trees[tabID]?.leaves().map(\.id) == [anchor.id])
  }

  /// A split closed while it waits for its launcher has nothing for Undo to bring back.
  @Test func aSplitClosedWhileStagingIsNotKeptForUndo() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let staging = Staging()
    let state = makeState(staging)
    let tabID = try #require(state.createTab())
    let anchor = try onlySurface(state, tabID)
    await waitUntil { anchor.surfaceCreationArmed }
    state.remoteTerminalStagerForTesting = Staging(gate: gate).stager(profile: Self.profile)
    state.undoCloseTimeout = .seconds(5)
    var recorded = false
    state.onCloseRecorded = { _ in recorded = true }

    let splitID = try state.createSplit(of: anchor.id, direction: .right, initialInput: nil).get()
    #expect(state.isAwaitingRemoteLaunch(splitID))
    #expect(state.closeSurface(id: splitID, confirmation: .skip))
    release.finish()

    #expect(!recorded)
    #expect(state.surfaceView(for: splitID) == nil)
  }

  /// A split whose host profile is gone opens no pane and tells the user.
  @Test func aRemoteSplitWithoutItsHostProfileTellsTheUser() throws {
    let staging = Staging()
    let state = makeState(staging)
    let tabID = try #require(state.createTab())
    let anchor = try onlySurface(state, tabID)
    state.remoteTerminalStagerForTesting = staging.stager(profile: nil)
    var messages: [String] = []
    state.onRemoteTerminalFailed = { messages.append($0) }

    #expect(state.createSplit(of: anchor.id, direction: .right, initialInput: nil) == .failure(.remoteFolder))
    #expect(state.trees[tabID]?.leaves().count == 1)
    #expect(messages.count == 1)
  }

  /// A script in a remote folder (C3c) is the launch's first command on the host, byte for
  /// byte; the local shell gets only the `ssh` line. The run script tab keeps its run state.
  @Test func aRemoteScriptIsTheLaunchsFirstCommand() async throws {
    let staging = Staging()
    let state = makeState(staging)
    let script = "printf '%s\\n' \"${(U)value}\" $HOME\nnpm run dev"

    let tabID = try #require(state.runScript(script))
    let surface = try onlySurface(state, tabID)
    await waitUntil { surface.surfaceCreationArmed }

    let launch = try #require(staging.launches.value.first)
    #expect(launch.firstCommand == script + "\n")
    #expect(surface.initialInputForTesting?.hasPrefix(" /usr/bin/ssh -t ") == true)
    #expect(surface.initialInputForTesting?.contains("npm") == false)
    #expect(state.runScriptTabId == tabID)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.hasFirstCommand == true)
  }

  /// A setup script runs first, then the command, in one first command; a working directory
  /// (CLI `create tab --path`) is a host path inside the folder.
  @Test func aRemoteTabTakesTheSetupScriptAndAHostDirectory() async throws {
    let staging = Staging()
    let state = makeState(staging)
    state.pendingSetupScript = true

    let tabID = try #require(
      state.createTab(
        setupScript: "make setup", initialInput: "make test",
        workingDirectoryOverride: URL(fileURLWithPath: "/home/dev/app/sub", isDirectory: true)))
    let surface = try onlySurface(state, tabID)
    await waitUntil { surface.surfaceCreationArmed }

    let launch = try #require(staging.launches.value.first)
    #expect(launch.firstCommand == "make setup\nmake test\n")
    #expect(launch.workingDirectory == "/home/dev/app/sub")
    #expect(!state.pendingSetupScript)
  }

  /// A pane that waits for its launcher has no native surface: an occlusion request (the
  /// worktree went to the background) is kept, and the new surface starts with it instead of
  /// Ghostty's visible default.
  @Test func aDeferredSurfaceKeepsItsOcclusionForTheNewSurface() {
    let view = GhosttySurfaceView(
      runtime: GhosttyRuntime(), workingDirectory: nil, fontSize: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      defersSurfaceCreation: true)
    view.setOcclusion(false)
    #expect(view.desiredOcclusionForTesting == false)

    var state = GhosttySurfaceView.OcclusionState()
    state.setDesired(false)
    let pending = state.resetForNewSurface()
    let applies = state.prepareToApply(false)
    #expect(pending == false)
    #expect(applies)
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

  /// While a remote pane's first command runs, a CLI waiter waits for its marker: a remote
  /// shell's OSC 133 is not the script's end (C3c).
  @Test(.timeLimit(.minutes(1))) func aWaiterInAScriptPaneWaitsForTheMarker() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: true)
    _ = state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: Self.ssh(4_242, nonce: nonce))
    state.processIsAliveForTesting = { _ in true }
    let waiter = state.waitForCommandFinished(surfaceID: surface.id)

    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)
    #expect(state.commandFinishedWaiters[surface.id] != nil)
    state.handleProgramStatus(marker("prowl-launch/\(nonce)/4", state: .error), surfaceID: surface.id)

    var results: [Int?] = []
    for await result in waiter { results.append(result.exitCode) }
    #expect(results == [4])
  }

  /// A script that sent no marker before its `ssh` ended did not run to its end: no success
  /// toast, no Close on Success, no notification, and the CLI waiter gets no status. The
  /// decision waits for the `ssh`'s finish, then for the marker grace.
  @Test(.timeLimit(.minutes(1))) func aScriptWithoutAMarkerCompletesNothing() async throws {
    let state = makeState(Staging())
    let clock = TestClock()
    state.remoteLaunchClock = clock
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: true)
    let ssh = Self.ssh(4_242, nonce: nonce)
    _ = state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: ssh)
    state.processIsAliveForTesting = { _ in false }
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }
    state.markSurfaceForCustomCommand(surface.id, name: "Build")
    state.markSurfaceForAutoClose(surface.id)
    let waiter = state.waitForCommandFinished(surfaceID: surface.id)

    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: nil) == nil)
    #expect(state.commandFinishedWaiters[surface.id] != nil)
    state.handleCommandFinished(exitCode: 0, durationNs: 60_000_000_000, surfaceId: surface.id)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.completed == false)
    // A local command that finishes within the grace takes none of the script's reactions.
    state.handleCommandFinished(exitCode: 0, durationNs: 60_000_000_000, surfaceId: surface.id)
    #expect(succeeded.isEmpty)
    #expect(state.isMarkedForAutoClose(surface.id))
    await clock.advance(by: WorktreeTerminalState.remoteMarkerGrace)

    var results: [Int?] = []
    for await result in waiter { results.append(result.exitCode) }
    #expect(results == [nil])
    #expect(succeeded.isEmpty)
    #expect(!state.isMarkedForAutoClose(surface.id))
    #expect(state.notifications.isEmpty)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.completed == true)
  }

  /// A remote shell's own OSC 133 can arrive after the `ssh` exited and just before the
  /// marker: the marker still counts within the grace.
  @Test(.timeLimit(.minutes(1))) func aMarkerRightAfterARemoteFinishStillCounts() async throws {
    let state = makeState(Staging())
    let clock = TestClock()
    state.remoteLaunchClock = clock
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: true)
    _ = state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: Self.ssh(4_242, nonce: nonce))
    state.processIsAliveForTesting = { _ in false }
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }
    state.markSurfaceForCustomCommand(surface.id, name: "Build")
    let waiter = state.waitForCommandFinished(surfaceID: surface.id)

    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)
    // The main thread runs other work before the marker's action.
    for _ in 0..<20 { await Task.yield() }
    state.handleProgramStatus(marker("prowl-launch/\(nonce)/0"), surfaceID: surface.id)
    await clock.advance(by: WorktreeTerminalState.remoteMarkerGrace)

    var results: [Int?] = []
    for await result in waiter { results.append(result.exitCode) }
    #expect(results == [0])
    #expect(succeeded == ["Build"])
  }

  /// A suspended `ssh` ends the session for Prowl: its script completes nothing, so a later
  /// local command does not take its toast or its Close on Success.
  @Test(.timeLimit(.minutes(1))) func aSuspendedSSHAbandonsItsScript() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: true)
    _ = state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: Self.ssh(4_242, nonce: nonce))
    state.processIsAliveForTesting = { _ in true }
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }
    state.markSurfaceForCustomCommand(surface.id, name: "Build")
    state.markSurfaceForAutoClose(surface.id)
    let waiter = state.waitForCommandFinished(surfaceID: surface.id)

    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: nil) == nil)
    var results: [Int?] = []
    for await result in waiter { results.append(result.exitCode) }
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)

    #expect(results == [nil])
    #expect(succeeded.isEmpty)
    #expect(!state.isMarkedForAutoClose(surface.id))
  }

  /// A remote tab that carries the pending setup script consumes it once its launcher is
  /// staged; a staging failure keeps it pending for the next tab.
  @Test func theSetupScriptIsConsumedOnlyOnceStaged() async throws {
    let failing = makeState(Staging(failure: RemoteRepositoryHostError.timedOut))
    var consumed = 0
    failing.onSetupScriptConsumed = { consumed += 1 }
    var messages: [String] = []
    failing.onRemoteTerminalFailed = { messages.append($0) }
    failing.pendingSetupScript = true
    _ = try #require(failing.createTab(setupScript: "make setup"))
    await waitUntil { !messages.isEmpty }
    #expect(consumed == 0)
    #expect(failing.pendingSetupScript)

    let state = makeState(Staging())
    state.onSetupScriptConsumed = { consumed += 1 }
    state.pendingSetupScript = true
    let tabID = try #require(state.createTab(setupScript: "make setup"))
    let surface = try onlySurface(state, tabID)
    #expect(consumed == 0)
    await waitUntil { surface.surfaceCreationArmed }
    #expect(consumed == 1)
    #expect(!state.pendingSetupScript)
  }

  /// A marker that arrives after a probe saw the `ssh` exit (the script ended with `exit`)
  /// still completes the script: Close on Success and the toast; the `ssh`'s finish after it
  /// completes nothing more.
  @Test func aMarkerAfterTheProbeSawTheSSHExitStillCounts() async throws {
    let state = makeState(Staging())
    let (surface, nonce) = try await startedRemotePane(state, hasFirstCommand: true)
    _ = state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: Self.ssh(4_242, nonce: nonce))
    state.processIsAliveForTesting = { _ in false }
    var succeeded: [String] = []
    state.onCustomCommandSucceeded = { name, _ in succeeded.append(name) }
    state.markSurfaceForCustomCommand(surface.id, name: "Build")
    state.markSurfaceForAutoClose(surface.id)

    #expect(state.activeRemoteLaunchOrigin(surfaceID: surface.id, foregroundSSH: nil) == nil)
    state.handleProgramStatus(marker("prowl-launch/\(nonce)/0"), surfaceID: surface.id)
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)

    #expect(succeeded == ["Build"])
    #expect(!state.isMarkedForAutoClose(surface.id))
  }

  /// A remote script tab closed and brought back by Undo waits for no marker any more: the
  /// marker found no origin while the pane was closed, so a later finish completes as usual.
  /// A CLI waiter for the script gets no status, never a later command's.
  @Test(.timeLimit(.minutes(1))) func undoBringsBackAScriptPaneThatWaitsForNoMarker() async throws {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(), undoCloseClock: TestClock(), skipsSurfaceCreationForTesting: true)
    let state = manager.state(for: RemoteRepositoryFixtures.gitRepository().worktrees[0])
    state.remoteTerminalStagerForTesting = Staging().stager(profile: Self.profile)
    let (surface, _) = try await startedRemotePane(state, hasFirstCommand: true)
    let tabID = try #require(state.tabID(containing: surface.id))
    let waiter = state.waitForCommandFinished(surfaceID: surface.id)

    #expect(state.closeTab(tabID, confirmation: .skip))
    #expect(manager.undoClose())
    state.handleCommandFinished(exitCode: 0, durationNs: 1, surfaceId: surface.id)

    var results: [Int?] = []
    for await result in waiter { results.append(result.exitCode) }
    #expect(results == [nil])
    #expect(state.surfaceView(for: surface.id) === surface)
    #expect(state.remoteLaunchOriginBySurface[surface.id]?.completed == true)
    #expect(!state.remoteLaunchHoldsWaiters(surfaceID: surface.id))
  }

  /// A restored remote leaf reconnects with a plain shell, never a script, where its session
  /// was on the host when that lies inside the folder, else in the folder (C5, R-9).
  @Test(.timeLimit(.minutes(1))) func aRestoredRemoteLeafReconnectsWithAPlainShell() async throws {
    let staging = Staging()
    let state = makeState(staging)
    func leaf(_ cwd: String?) -> TerminalLayoutSnapshotPayload.SnapshotSplitNode {
      .leaf(
        surfaceID: UUID().uuidString,
        remote: .init(hostProfileID: RemoteRepositoryFixtures.hostProfileID.uuidString, cwdPath: cwd))
    }
    let tabs = [leaf("/home/dev/app/api/../web"), leaf("/home/dev/other"), leaf(nil)].map { node in
      TerminalLayoutSnapshotPayload.SnapshotTab(
        tabID: UUID().uuidString, title: "app 1", customTitle: nil, icon: nil, splitRoot: node)
    }
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: state.worktree.id, selectedTabID: nil, tabs: tabs)

    #expect(state.applyLayoutSnapshot(snapshot))
    await waitUntil { staging.launches.value.count == 3 }

    let launches = staging.launches.value
    #expect(Set(launches.map(\.workingDirectory)) == ["/home/dev/app/web", "/home/dev/app"])
    #expect(launches.filter { $0.workingDirectory == "/home/dev/app" }.count == 2)
    #expect(launches.allSatisfy { $0.firstCommand == nil })
    for surface in state.surfaces.values {
      await waitUntil { surface.surfaceCreationArmed }
      #expect(surface.initialInputForTesting?.hasPrefix(" /usr/bin/ssh -t ") == true)
      #expect(state.remoteLaunchOriginBySurface[surface.id] != nil)
    }
  }

  /// A remote folder's saved layout restores when its terminals first open, once; the panes
  /// reconnect then, not at launch (C5).
  @Test(.timeLimit(.minutes(1))) func aPendingRemoteLayoutRestoresWhenTheFolderOpens() async throws {
    let staging = Staging()
    let state = makeState(staging)
    var started = 0
    state.onRemoteLaunchStarted = { started += 1 }
    let tabID = UUID().uuidString
    state.pendingLayoutSnapshot = .init(
      worktreeID: state.worktree.id, selectedTabID: tabID,
      tabs: [
        .init(
          tabID: tabID, title: "app 1", customTitle: nil, icon: nil,
          splitRoot: .leaf(
            surfaceID: UUID().uuidString,
            remote: .init(hostProfileID: RemoteRepositoryFixtures.hostProfileID.uuidString, cwdPath: "/home/dev/app")))
      ])
    #expect(staging.launches.value.isEmpty)

    state.ensureInitialTab(focusing: false)

    #expect(state.pendingLayoutSnapshot == nil)
    #expect(state.tabManager.tabs.map(\.id.rawValue.uuidString) == [tabID])
    await waitUntil { started == 1 }
    #expect(staging.launches.value.count == 1)
  }

  /// A remote folder whose host profile is gone is not restored.
  @Test func aRemoteFolderWithoutItsHostProfileIsNotRestored() {
    let state = makeState(Staging(), profile: nil)
    let tabID = UUID().uuidString
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: state.worktree.id, selectedTabID: tabID,
      tabs: [
        .init(
          tabID: tabID, title: nil, customTitle: nil, icon: nil,
          splitRoot: .leaf(
            surfaceID: UUID().uuidString,
            remote: .init(hostProfileID: RemoteRepositoryFixtures.hostProfileID.uuidString, cwdPath: nil)))
      ])

    #expect(!state.applyLayoutSnapshot(snapshot))
    #expect(state.tabManager.tabs.isEmpty)
  }

  /// A snapshot written before remote leaves decodes with no remote origin.
  @Test func anOlderLayoutLeafDecodesWithoutARemoteOrigin() throws {
    let json = #"{"kind":"leaf","surfaceID":"A","cwdPath":"/tmp"}"#
    let node = try JSONDecoder().decode(TerminalLayoutSnapshotPayload.SnapshotSplitNode.self, from: Data(json.utf8))
    #expect(node.remote == nil)
    #expect(node.cwdPath == "/tmp")
  }

  // MARK: - The typed line

  private static let overrides =
    "-o RemoteCommand=none -o SessionType=default -o ForkAfterAuthentication=no -o StdinNull=no"

  /// A host whose SSH configuration sets a `RemoteCommand` (such as `tmux attach`) still runs
  /// the launcher: the typed line overrides it, so `ssh` does not refuse the command. No
  /// network: the `ProxyCommand` fails at once.
  @Test func theTypedLineOverridesAConfiguredRemoteCommand() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "prowl-ssh-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let config = home.appending(path: "config").path(percentEncoded: false)
    try Data(
      """
      Host target
        RemoteCommand tmux attach
        SessionType none
        ProxyCommand /usr/bin/false

      """.utf8
    ).write(to: URL(filePath: config))
    let line = try RemoteTerminalLine.typed(
      recipe: SSHConnectionRecipe(destination: "target", options: ["-F", config, "-o", "BatchMode=yes"]),
      launcherPath: "/home/dev/.cache/prowl/launch/0123456789abcdef/launch.sh")
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", line + "\n"]
    process.environment = ["HOME": home.path(percentEncoded: false), "PATH": "/usr/bin:/bin"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    #expect(!text.contains("Cannot execute command-line and remote command"), "\(text)")
    #expect(!text.lowercased().contains("bad configuration option"), "\(text)")
    #expect(process.terminationStatus == 255, "\(text)")
  }

  @Test func theTypedLineQuotesWhatIsNotSafeAndRefusesWhatNoShellTypesTheSame() throws {
    let path = "/home/dev/.cache/prowl/launch/0123456789abcdef/launch.sh"
    #expect(
      try RemoteTerminalLine.typed(recipe: SSHConnectionRecipe(destination: "mini"), launcherPath: path)
        == " /usr/bin/ssh -t \(Self.overrides) -- mini exec sh \(path)\n")
    #expect(
      try RemoteTerminalLine.typed(
        recipe: SSHConnectionRecipe(destination: "dev@mini", options: ["-F", "it's config", "-o", "SendEnv=A*"]),
        launcherPath: path)
        == " /usr/bin/ssh -t \(Self.overrides) -F 'it'\\''s config' -o 'SendEnv=A*' -- dev@mini exec sh \(path)\n")
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
