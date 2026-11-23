import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorKeyBarTests {
  /// Return confirms the row the arrows chose, so it leads both bars. Control-C can end an
  /// agent and stays last there; in a shell it is the common interrupt and comes right after.
  @Test func keysAreOrderedByUse() {
    #expect(
      MirrorKeyBar.keys(agent: true).map(\.token)
        == ["enter", "up", "down", "esc", "tab", "shift-tab", "left", "right", "ctrl-c"])
    #expect(
      MirrorKeyBar.keys(agent: false).map(\.token)
        == ["enter", "ctrl-c", "tab", "up", "down", "esc", "left", "right", "shift-tab"])
  }

  /// Both bars offer every key the Host accepts, and nothing else.
  @Test func everyAllowedKeyIsOnBothBars() {
    for agent in [true, false] {
      #expect(Set(MirrorKeyBar.keys(agent: agent).map(\.token)) == MirrorCommandRequest.AgentKeys.allowed)
    }
  }
}
