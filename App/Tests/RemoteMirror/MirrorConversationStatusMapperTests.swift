import Foundation
import Testing

@testable import Prowl

struct MirrorConversationStatusMapperTests {
  @Test func emitsOnlyChangesWithKindAndSource() {
    var mapper = MirrorConversationStatusMapper()
    var pane = PaneAgentState(detectedAgent: .claude, state: .working)
    pane.decision = .init(state: .working, reason: .programStatus(.working))
    let working = mapper.event(for: pane, at: Date())
    #expect(working?.kind == .agentStatus && working?.source == .osc)
    #expect(mapper.event(for: pane, at: Date()) == nil)
    pane.state = .blocked
    pane.decision = .init(state: .blocked, reason: .programStatus(.blocked(.permission)))
    guard case .status(let blocked) = mapper.event(for: pane, at: Date())?.payload else {
      Issue.record("expected a status event")
      return
    }
    #expect(blocked.state == .blocked && blocked.kind == "permission" && blocked.reason == "osc.blocked.permission")
    pane.decision = .init(state: .blocked, reason: .screen(.noRuleMatched))
    guard let screen = mapper.event(for: pane, at: Date()), case .status(let fromScreen) = screen.payload else {
      Issue.record("expected a status event")
      return
    }
    #expect(screen.source == .screen && fromScreen.kind == "unspecified")
    pane.state = .idle
    pane.decision = .init(state: .idle, reason: .native(.idle))
    #expect(mapper.event(for: pane, at: Date())?.source == .native)
    #expect(mapper.event(for: PaneAgentState(state: .working), at: Date()) == nil)
  }

  @Test func resetRestatesTheCurrentStatus() {
    var mapper = MirrorConversationStatusMapper()
    let pane = PaneAgentState(detectedAgent: .codex, state: .working)
    #expect(mapper.event(for: pane, at: Date()) != nil)
    #expect(mapper.event(for: pane, at: Date()) == nil)
    mapper.reset()
    #expect(mapper.event(for: pane, at: Date()) != nil)
  }
}
