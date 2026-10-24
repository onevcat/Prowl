import Foundation
import IdentifiedCollections
import Testing

@testable import Prowl

struct RemoteAgentPresentationTests {
  private let key = ConnectionKey(user: "alice", hostname: "box.example")
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  @Test func healthIsSeparateFromTheAgentState() {
    let live = RemoteAgentContext(connection: key, correlation: .correlated, confirmedAt: now, now: now)
    #expect(RemoteAgentHealth(live) == .live)
    let unknown = RemoteAgentContext(
      connection: key, correlation: .correlated, confirmedAt: now, now: now, stateKnown: false)
    #expect(RemoteAgentHealth(unknown) == .unknownState)
    let quiet = RemoteAgentContext(
      connection: key, correlation: .correlated, confirmedAt: now, now: now.addingTimeInterval(12))
    #expect(RemoteAgentHealth(quiet) == .lastSeen(now))
    let never = RemoteAgentContext(connection: key, correlation: .probeUnavailable(nil), confirmedAt: nil, now: now)
    #expect(RemoteAgentHealth(never) == .unavailable)
  }

  @Test func onlyAConfirmedStateOrABlockedStateIsEmphasized() {
    let live = RemoteAgentContext(connection: key, correlation: .correlated, confirmedAt: now, now: now)
    #expect(RemoteAgentPresentation.emphasizesState(.working, remote: live))
    let quiet = RemoteAgentContext(
      connection: key, correlation: .correlated, confirmedAt: now, now: now.addingTimeInterval(12))
    #expect(!RemoteAgentPresentation.emphasizesState(.working, remote: quiet))
    #expect(!RemoteAgentPresentation.emphasizesState(.idle, remote: quiet))
    // A blocked agent stops reporting, so it goes stale while it still waits for the user.
    #expect(RemoteAgentPresentation.emphasizesState(.blocked, remote: quiet))
    let never = RemoteAgentContext(
      connection: key, correlation: .probeUnavailable(.hostKey), confirmedAt: nil, now: now, isUnprobed: true)
    #expect(RemoteAgentPresentation.emphasizesState(.blocked, remote: never))
    // The pill reads "Unknown", not "Blocked".
    let unknown = RemoteAgentContext(
      connection: key, correlation: .correlated, confirmedAt: now, now: now, stateKnown: false)
    #expect(!RemoteAgentPresentation.emphasizesState(.blocked, remote: unknown))
  }

  @Test func theHostLabelFallsBackWhileTheConnectionIsUnresolved() {
    let resolved = RemoteAgentContext(connection: key, correlation: .correlated, confirmedAt: now, now: now)
    #expect(RemoteAgentPresentation.hostLabel(for: resolved) == "alice@box.example")
    let unresolved = RemoteAgentContext(
      connection: nil, correlation: .unsupported("-W"), confirmedAt: now, now: now, isUnprobed: true)
    #expect(RemoteAgentPresentation.hostLabel(for: unresolved) == "Remote host")
  }

  @Test func theExplanationNamesTheReason() {
    let hostKey = RemoteAgentContext(
      connection: key, correlation: .probeUnavailable(.hostKey), confirmedAt: now, now: now, isUnprobed: true)
    #expect(
      RemoteAgentPresentation.explanation(for: hostKey)
        == "Prowl cannot read alice@box.example: the host key is unknown or changed. "
        + "The status comes only from the agent's own terminal reports, so it can be out of date.")
    let unmapped = RemoteAgentContext(connection: key, correlation: .unmapped, confirmedAt: now, now: now)
    #expect(RemoteAgentPresentation.explanation(for: unmapped).contains("SendEnv"))
    let exit = RemotePaneCorrelation.probeUnavailable(.exit(255, "Connection closed by 10.0.0.2 port 22"))
    #expect(
      RemoteAgentPresentation.correlationExplanation(exit, host: "h")
        == "Prowl cannot read h: Connection closed by 10.0.0.2 port 22.")
    // tmux drops OSC 7501, so the pane names no fallback that would not work.
    let tmux = RemoteAgentPresentation.paneIssueExplanation(.tmuxUnreachable, host: "h")
    #expect(tmux.contains("tmux -S"))
    #expect(!tmux.contains("OSC 7501"))
    #expect(AgentsCommandHandler.correlation(.tmuxUnreachable) == ("tmux_unreachable", nil))
  }

  /// A remote agent's directory is on its host (docs-ai 084 C4): it never resolves to a
  /// local worktree with the same path, only to its own remote folder.
  @Test func aRemoteAgentDirectoryResolvesOnlyToItsRemoteFolder() {
    let folder = RemoteRepositoryFixtures.gitRepository(path: "/tmp/repo")
    var entry = ActiveAgentEntry(
      id: UUID(), worktreeID: folder.worktrees[0].id, worktreeName: "main",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/api", isDirectory: true),
      tabID: TerminalTabID(rawValue: UUID()), paneTitle: "claude", surfaceID: UUID(), paneIndex: 1,
      iconLookupToken: "claude", agent: .claude, session: nil, rawState: .idle, displayState: .idle,
      lastChangedAt: now)
    #expect(entry.localWorkingDirectory != nil)
    #expect(entry.remoteWorktreeID == nil)
    entry.remote = RemoteAgentContext(connection: key, correlation: .correlated, confirmedAt: now, now: now)
    #expect(entry.localWorkingDirectory == nil)
    // A later `ssh` from the same pane to another host: the same path is not this folder's.
    #expect(entry.remoteWorktreeID == nil)
    entry.remote?.hostProfileID = UUID()
    #expect(entry.remoteWorktreeID == nil)
    entry.remote?.hostProfileID = RemoteRepositoryFixtures.hostProfileID
    #expect(entry.remoteWorktreeID == folder.worktrees[0].id)
    var outside = ActiveAgentEntry(
      id: entry.id, worktreeID: entry.worktreeID, worktreeName: "main",
      workingDirectory: URL(fileURLWithPath: "/tmp/repository", isDirectory: true), tabID: entry.tabID,
      paneTitle: "claude", surfaceID: entry.surfaceID, paneIndex: 1, iconLookupToken: "claude", agent: .claude,
      session: nil, rawState: .idle, displayState: .idle, lastChangedAt: now)
    outside.remote = entry.remote
    #expect(outside.remoteWorktreeID == nil)
  }

  @Test func theRowTooltipAddsTheExplanationForRemoteAgents() {
    var entry = ActiveAgentEntry(
      id: UUID(), worktreeID: "/tmp/repo", worktreeName: "repo", workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()), paneTitle: "claude", surfaceID: UUID(), paneIndex: 1,
      iconLookupToken: "claude", agent: .claude, session: nil, rawState: .idle, displayState: .idle,
      lastChangedAt: now)
    #expect(ActiveAgentRowPresentation.helpText(for: entry, branchName: "main", showTabTitles: true) == "main")
    #expect(ActiveAgentRowPresentation.remoteHelpText(for: entry) == nil)
    entry.remote = RemoteAgentContext(connection: key, correlation: .correlated, confirmedAt: now, now: now)
    #expect(
      ActiveAgentRowPresentation.helpText(for: entry, branchName: "main", showTabTitles: true)
        == "main\nProwl reads this agent from alice@box.example over a separate SSH connection.")
    // The island roster shows the same reason on its own.
    entry.remote = RemoteAgentContext(
      connection: key, correlation: .unmapped, confirmedAt: now, now: now, isUnprobed: true)
    let island = try? #require(ActiveAgentRowPresentation.remoteHelpText(for: entry))
    #expect(island?.contains("AcceptEnv") == true)
    #expect(island?.contains("terminal reports") == true)
  }
}
