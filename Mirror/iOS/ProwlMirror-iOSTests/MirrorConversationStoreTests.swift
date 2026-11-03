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

  @Test func promptsResolveInPlaceAndBlockedStatusIsAnItem() {
    let prompt = MirrorConversationEvent.Prompt(id: "p", kind: .question, freeform: true)
    var store = MirrorConversationStore()
    store.apply(events: [
      .init(.promptOpened, .prompt(prompt), at: nil, source: .transcript, sequence: 1),
      .init(.agentStatus, .status(.init(state: .blocked, kind: "question")), at: nil, source: .osc, sequence: 2),
      .init(.promptResolved, .prompt(.init(id: "p", kind: .question, freeform: true, outcome: .answered)), at: nil, source: .transcript, sequence: 3),
      .init(.agentStatus, .status(.init(state: .working)), at: nil, source: .osc, sequence: 4),
    ], sequence: 4)
    #expect(store.items.count == 2)
    guard case .prompt(_, _, let resolved, _) = store.items[0] else {
      Issue.record("expected a prompt item")
      return
    }
    #expect(resolved?.outcome == .answered)
    #expect(store.agentState == .working)
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
}
