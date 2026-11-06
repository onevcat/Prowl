import Foundation
import Testing

@testable import ProwlMirror_iOS

struct MirrorConversationStoreTests {
  private static func fixture(_ name: String) throws -> [MirrorConversationEvent] {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appending(path: "Mirror/Fixtures/conversation/\(name).events.jsonl")
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map { try JSONDecoder().decode(MirrorConversationEvent.self, from: Data($0.utf8)) }
  }

  @Test(arguments: ["claude-review-1038", "codex-review-1038"])
  func fixtureSnapshotsBecomeItems(name: String) throws {
    let events = try Self.fixture(name)
    var store = MirrorConversationStore()
    store.apply(snapshot: events, gap: false, sequence: events.last?.sequence ?? 0, session: nil, resumed: false)
    #expect(store.events.count == events.count)
    #expect(store.latestSequence == events.last?.sequence)
    #expect(store.session?.id != nil)
    #expect(!store.items.isEmpty)
    let tools = store.items.filter { if case .tool = $0 { return true } else { return false } }
    let merged = tools.allSatisfy { item in
      if case .tool(_, _, let end, _, _) = item { return end != nil }
      return false
    }
    #expect(tools.count > 20 && merged)
    #expect(store.items.contains { if case .user = $0 { return true } else { return false } })
    #expect(store.items.contains { if case .assistant = $0 { return true } else { return false } })
  }

  @Test func resumedSnapshotAppendsAndDuplicatesAreIgnored() throws {
    let events = try Self.fixture("codex-review-1038")
    var store = MirrorConversationStore()
    let half = Array(events.prefix(40))
    store.apply(snapshot: half, gap: false, sequence: half.last!.sequence, session: nil, resumed: false)
    let before = store.items.count
    store.apply(events: Array(events[38..<60]), sequence: events[59].sequence)
    #expect(store.events.count == 60)
    #expect(store.items.count >= before)
    store.apply(snapshot: Array(events[60...]), gap: false, sequence: events.last!.sequence, session: nil, resumed: true)
    #expect(store.events.count == events.count)
    store.apply(snapshot: [], gap: true, sequence: 9999, session: .init(id: "fresh"), resumed: false)
    #expect(store.events.isEmpty && store.gap && store.session?.id == "fresh" && store.latestSequence == 9999)
  }

  @Test func queuedMessagesDisappearWhenTaken() {
    let queued = MirrorConversationEvent(.userQueued, .message(.init(text: .init("later"), origin: .queued)), at: nil, source: .transcript, sequence: 1)
    let taken = MirrorConversationEvent(.userUnqueued, .message(.init(text: .init("later"), origin: .queued)), at: nil, source: .transcript, sequence: 2)
    var store = MirrorConversationStore()
    store.apply(events: [queued], sequence: 1)
    #expect(store.items.count == 1)
    store.apply(events: [taken], sequence: 2)
    #expect(store.items.isEmpty)
  }

  /// The Host sends an open multi-select menu again under its id when a box changes: one row,
  /// with the new boxes (089 S4 follow-up).
  @Test func reopenedScreenPromptUpdatesItsRow() {
    func menu(_ checked: [Bool]) -> MirrorConversationEvent.Prompt {
      .init(
        id: "screen:m.1", kind: .question, title: "Which fruits?",
        choices: checked.enumerated().map { .init(id: String($0.offset + 1), label: "F\($0.offset)", checked: $0.element) },
        freeform: true, multiSelect: true)
    }
    var store = MirrorConversationStore()
    store.apply(
      events: [
        .init(.promptOpened, .prompt(menu([false, false])), at: nil, source: .screen, sequence: 1),
        .init(.promptOpened, .prompt(menu([true, false])), at: nil, source: .screen, sequence: 2),
      ], sequence: 2)
    #expect(store.items.count == 1)
    guard case .prompt(_, let prompt, nil, _) = store.items.first else {
      Issue.record("expected an open prompt row")
      return
    }
    #expect(prompt.choices?.map(\.checked) == [true, false])
  }

  /// A queued message taken before tools finish must not shift their results onto other rows,
  /// or past the end of the list (a crash on device).
  @Test func takingAQueuedMessageKeepsLaterToolsMatched() {
    typealias Event = MirrorConversationEvent
    let message = Event.Message(text: .init("later"), origin: .queued)
    var store = MirrorConversationStore()
    store.apply(
      events: [
        .init(.userQueued, .message(message), at: nil, source: .transcript, sequence: 1),
        .init(
          .toolStarted, .toolStart(.init(id: "a", name: "Bash", kind: .shell, title: "a")),
          at: nil, source: .transcript, sequence: 2),
        .init(
          .toolStarted, .toolStart(.init(id: "b", name: "Bash", kind: .shell, title: "b")),
          at: nil, source: .transcript, sequence: 3),
        .init(.userUnqueued, .message(message), at: nil, source: .transcript, sequence: 4),
        .init(.toolCompleted, .toolEnd(.init(id: "b", status: .succeeded)), at: nil, source: .transcript, sequence: 5),
        .init(.toolCompleted, .toolEnd(.init(id: "a", status: .error)), at: nil, source: .transcript, sequence: 6),
      ], sequence: 6)
    let ends = store.items.compactMap { item -> (String, Event.ToolStatus?)? in
      guard case .tool(_, let start, let end, _, _) = item else { return nil }
      return (start.id, end?.status)
    }
    #expect(ends.map(\.0) == ["a", "b"])
    #expect(ends.map(\.1) == [.error, .succeeded])
  }

  @Test func promptsResolveInPlaceAndBlockedStatusIsAnItem() {
    let prompt = MirrorConversationEvent.Prompt(id: "p", kind: .question, freeform: true)
    var store = MirrorConversationStore()
    store.apply(events: [
      .init(.promptOpened, .prompt(prompt), at: nil, source: .transcript, sequence: 1),
      .init(.agentStatus, .status(.init(state: .blocked, kind: "question")), at: nil, source: .osc, sequence: 2),
      .init(.promptResolved, .prompt(.init(id: "p", kind: .question, freeform: true, outcome: .answered)), at: nil, source: .transcript, sequence: 3),
      .init(.agentStatus, .status(.init(state: .working)), at: nil, source: .osc, sequence: 4),
    ], sequence: 4)
    // The attention row goes away once the agent is no longer blocked (docs-ai 089 D3).
    #expect(store.items.count == 1)
    guard case .prompt(_, _, let resolved, _) = store.items[0] else {
      Issue.record("expected a prompt item")
      return
    }
    #expect(resolved?.outcome == .answered)
    #expect(store.agentState == .working)
  }
}

extension MirrorConversationStoreTests {
  @Test func attentionShowsOnlyWhileTheAgentIsBlocked() {
    func status(_ state: MirrorConversationEvent.AgentState, _ sequence: UInt64) -> MirrorConversationEvent {
      .init(.agentStatus, .status(.init(state: state, kind: state == .blocked ? "permission" : nil)),
        at: nil, source: .osc, sequence: sequence)
    }
    var store = MirrorConversationStore()
    store.apply(events: [status(.blocked, 1)], sequence: 1)
    #expect(store.items.count == 1)
    store.apply(events: [status(.working, 2), status(.blocked, 3)], sequence: 3)
    let attentions = store.items.filter { if case .attention = $0 { true } else { false } }
    #expect(attentions.map(\.id) == [3])
    store.apply(events: [status(.idle, 4)], sequence: 4)
    #expect(store.items.isEmpty)
  }
}

@MainActor
struct MirrorConversationFixtureSessionTests {
  @Test func conversationFixtureSessionGoesLiveWithItems() {
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex")
    #expect(session.mode == .conversation)
    #expect(session.status == .live)
    #expect(session.supportsConversation)
    #expect(!session.conversation.items.isEmpty)
  }

  /// In Terminal the conversation stream is paused, so the roster's state counts (089 review
  /// S5-R1); back in Chat the stream's status does.
  @Test func terminalModeFollowsTheRosterState() throws {
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex", status: .working)
    session.switchMode(.screen)
    #expect(session.mode == .screen)
    var pane = try #require(session.pane)
    pane.agentState = .idle
    session.refreshDescriptor(pane)
    // The paused stream still says working; the roster says idle.
    #expect(session.conversation.status?.state == .working)
    #expect(session.agentState == .idle)
    pane.agentState = .working
    session.refreshDescriptor(pane)
    #expect(session.agentState == .working)
  }

  /// 089 review R4: Terminal pauses the conversation, so its status stays `working` after the
  /// agent leaves. The shell left behind keeps its key bar but offers no agent Stop, which
  /// would press Escape into the shell.
  @Test func shellLeftByTheAgentOffersKeysButNoStop() throws {
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex", status: .working)
    session.switchMode(.screen)
    var pane = try #require(session.pane)
    pane.agent = nil
    pane.agentState = nil
    pane.conversation = .unsupported
    session.refreshDescriptor(pane)
    #expect(session.conversation.status?.state == .working)
    #expect(session.keysAvailable)
    #expect(session.agentState == nil)
    #expect(!session.canStopAgent)
  }

  @Test func rosterDescriptorReplacesTheOpenedOne() throws {
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex")
    var current = try #require(session.pane)
    current.agent = "claude"
    current.subtitle = "Renamed · main"
    session.refreshDescriptor(current)
    #expect(session.pane?.agent == "claude")
    #expect(session.pane?.subtitle == "Renamed · main")
    let other = MirrorPaneDescriptor(id: UUID(), title: "Other", directory: "/", busy: false, agent: "pi")
    session.refreshDescriptor(other)
    #expect(session.pane?.agent == "claude")
  }

  @Test func launchedAgentSurvivesARosterThatHasNotDetectedItYet() throws {
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex")
    let launched = try #require(session.pane)
    session.expectAgent(of: launched)
    var undetected = launched
    undetected.agent = nil
    undetected.subtitle = "Shell · main"
    undetected.conversation = .unsupported
    session.refreshDescriptor(undetected)
    #expect(session.pane?.agent == "codex")
    #expect(session.pane?.subtitle == launched.subtitle)
    var detected = launched
    detected.agent = "claude"
    detected.subtitle = "Claude · main"
    session.refreshDescriptor(detected)
    #expect(session.pane?.agent == "claude")
    session.refreshDescriptor(undetected)
    #expect(session.pane?.agent == nil)
  }

  @Test func launchExpectationEndsAtItsDeadlineWithoutAnyRosterChange() async throws {
    let clock = HostTestClock()
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex", clock: clock)
    let launched = try #require(session.pane)
    session.expectAgent(of: launched, for: .seconds(30))
    var undetected = launched
    undetected.agent = nil
    undetected.subtitle = "Shell · main"
    session.refreshDescriptor(undetected)
    #expect(session.pane?.agent == "codex")
    #expect(await clock.nextSleep() == .seconds(30))
    await clock.advance()
    for _ in 0..<100 where session.pane?.agent != nil { await Task.yield() }
    #expect(session.pane?.agent == nil)
    #expect(session.pane?.subtitle == "Shell · main")
  }

  @Test func disconnectEndsTheLaunchExpectation() throws {
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex")
    let launched = try #require(session.pane)
    session.expectAgent(of: launched)
    var undetected = launched
    undetected.agent = nil
    undetected.subtitle = "Shell · main"
    session.refreshDescriptor(undetected)
    #expect(session.pane?.agent == "codex")
    session.disconnect()
    #expect(session.pane?.agent == nil)
    session.retry()
    session.refreshDescriptor(undetected)
    #expect(session.pane?.agent == nil)
    #expect(session.pane?.subtitle == "Shell · main")
  }
}
