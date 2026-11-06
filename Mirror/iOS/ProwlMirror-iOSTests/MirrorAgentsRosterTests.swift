import Foundation
import Testing

@testable import ProwlMirror_iOS

struct MirrorAgentsRosterTests {
  private static func pane(
    _ tab: String, project: String?, agent: String? = "claude", state: MirrorPaneDescriptor.DisplayState? = .idle,
    order: Int? = nil, changed: String? = nil
  ) -> MirrorPaneDescriptor {
    var pane = MirrorPaneDescriptor(
      id: UUID(), title: tab, directory: "/x", busy: false, projectName: project, subtitle: "\(tab) · main",
      agent: agent)
    pane.displayState = agent == nil ? nil : state
    pane.tabTitle = tab
    pane.projectOrder = order
    pane.stateChangedAt = changed
    return pane
  }

  @Test func projectsFollowTheSidebarOrderThenTheName() {
    let roster = MirrorAgentsRoster(panes: [
      Self.pane("a", project: "zeta"),
      Self.pane("b", project: "beta", order: 1),
      Self.pane("c", project: "alpha", order: 0),
      Self.pane("d", project: "gamma"),
    ])
    #expect(roster.projectNames == ["alpha", "beta", "gamma", "zeta"])
  }

  @Test func agentsSortByUrgencyAndTerminalsFoldApart() {
    let roster = MirrorAgentsRoster(panes: [
      Self.pane("idle", project: "p", state: .idle),
      Self.pane("shell", project: "p", agent: nil),
      Self.pane("done", project: "p", state: .done),
      Self.pane("blocked", project: "p", state: .blocked),
      Self.pane("working", project: "p", state: .working),
    ])
    let project = try! #require(roster.projects.first)
    #expect(project.agents.map(\.displayTitle) == ["blocked", "working", "done", "idle"])
    #expect(project.terminals.map(\.displayTitle) == ["shell"])
    #expect(project.hasBlocked)
    #expect(roster.counts == [.blocked: 1, .working: 1, .done: 1, .idle: 1])
  }

  @Test func newerChangesComeFirstWithinAState() {
    let roster = MirrorAgentsRoster(panes: [
      Self.pane("older", project: "p", state: .done, changed: "2026-11-05T10:00:00.000Z"),
      Self.pane("newer", project: "p", state: .done, changed: "2026-11-05T11:00:00.000Z"),
    ])
    #expect(roster.projects.first?.agents.map(\.displayTitle) == ["newer", "older"])
  }

  @Test func stateFilterKeepsOnlyThatStateAndHidesTerminals() {
    let panes = [
      Self.pane("a", project: "one", state: .blocked),
      Self.pane("b", project: "two", state: .done),
      Self.pane("c", project: "one", state: .idle),
      Self.pane("shell", project: "one", agent: nil),
    ]
    let roster = MirrorAgentsRoster(panes: panes, state: .blocked)
    #expect(roster.projectNames == ["one"])
    #expect(roster.projects.first?.agents.map(\.displayTitle) == ["a"])
    #expect(roster.projects.first?.terminals.isEmpty == true)
    #expect(roster.counts[.done] == 1)
  }

  @Test func stateFallsBackToTheAgentStateOfOlderHosts() {
    var old = Self.pane("x", project: "p")
    old.displayState = nil
    old.agentState = .working
    #expect(MirrorPaneState(old) == .working)
    old.agentState = nil
    #expect(MirrorPaneState(old) == .unknown)
    #expect(MirrorPaneState(Self.pane("s", project: "p", agent: nil)) == .terminal)
    #expect(MirrorPaneState(Self.pane("d", project: "p", state: .done)) == .done)
  }

  @Test func repositoryColorsReadPresetsAndHex() {
    #expect(MirrorRepositoryColor.color("mint") != nil)
    #expect(MirrorRepositoryColor.color("#FF8000") != nil)
    #expect(MirrorRepositoryColor.color("#FF80") == nil)
    #expect(MirrorRepositoryColor.color("plaid") == nil)
    #expect(MirrorRepositoryColor.color(nil) == nil)
  }

  @Test func agentIconsCoverTheMacMarks() {
    #expect(MirrorAgentIcon.assetName(for: "claude") == "ClaudeCode")
    #expect(MirrorAgentIcon.assetName(for: "cursor-agent") == "Cursor")
    #expect(MirrorAgentIcon.assetName(for: "qodercli") == nil)
    #expect(MirrorAgentIcon.displayName(for: nil) == "Terminal")
  }

  @Test func baguaFramesPingPong() {
    let indices = (0..<16).map { MirrorBaguaIndicator.frameIndex(at: Date(timeIntervalSinceReferenceDate: Double($0) * 0.12 + 0.01)) }
    #expect(indices == [0, 1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1, 0, 1])
  }

  @Test func descriptorDecodesTheNewRosterFields() throws {
    let json = #"""
      {"id":"03F5535A-D08C-498C-B70B-C665AC8D02CB","title":"t","directory":"/x","busy":false,
       "displayState":"done","stateChangedAt":"2026-11-05T12:00:00.000Z","tabTitle":"Tab","worktreeName":"main",
       "repositoryColor":"#00FF00","projectOrder":3,"groupName":"Apps"}
      """#
    let pane = try JSONDecoder().decode(MirrorPaneDescriptor.self, from: Data(json.utf8))
    #expect(pane.displayState == .done && pane.tabTitle == "Tab" && pane.projectOrder == 3)
    #expect(pane.stateChangedDate != nil)
    let legacy = try JSONDecoder().decode(
      MirrorPaneDescriptor.self, from: Data(#"{"id":"03F5535A-D08C-498C-B70B-C665AC8D02CB","title":"t","directory":"/x","busy":false}"#.utf8))
    #expect(legacy.displayState == nil && legacy.displayTitle == "t")
  }
}

@MainActor
struct MirrorHostStoreSelectionTests {
  @Test func selectionPersistsAndFallsBackToTheFirstHost() {
    let suite = "mirror-host-store-selection-tests"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = MirrorHostStore(defaults: defaults)
    let first = store.upsert(address: "10.0.0.1", port: 7880, hostID: nil)
    let second = store.upsert(address: "10.0.0.2", port: 7880, hostID: nil)
    #expect(store.selectedHost?.id == second.id)
    store.select(first.id)
    #expect(MirrorHostStore(defaults: defaults).selectedHost?.id == first.id)
    store.updateHostName(first.id, name: "Studio")
    #expect(store.host(id: first.id)?.displayName == "Studio")
    store.rename(first.id, alias: "Desk")
    #expect(store.host(id: first.id)?.displayName == "Desk")
    store.remove(first.id)
    #expect(store.selectedHost?.id == second.id)
    defaults.removePersistentDomain(forName: suite)
  }
}
