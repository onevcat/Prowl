import Foundation
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
  }

  @Test func theRowTooltipAddsTheExplanationForRemoteAgents() {
    var entry = ActiveAgentEntry(
      id: UUID(), worktreeID: "/tmp/repo", worktreeName: "repo", workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()), paneTitle: "claude", surfaceID: UUID(), paneIndex: 1,
      iconLookupToken: "claude", agent: .claude, session: nil, rawState: .idle, displayState: .idle,
      lastChangedAt: now)
    #expect(ActiveAgentRowPresentation.helpText(for: entry, branchName: "main", showTabTitles: true) == "main")
    entry.remote = RemoteAgentContext(connection: key, correlation: .correlated, confirmedAt: now, now: now)
    #expect(
      ActiveAgentRowPresentation.helpText(for: entry, branchName: "main", showTabTitles: true)
        == "main\nProwl reads this agent from alice@box.example over a separate SSH connection.")
  }
}
