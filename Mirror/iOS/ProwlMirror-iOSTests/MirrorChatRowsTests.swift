import Foundation
import Testing

@testable import ProwlMirror_iOS

struct MirrorChatRowsTests {
  private typealias Event = MirrorConversationEvent

  private static func tool(
    _ id: UInt64, _ kind: Event.ToolKind = .shell, end status: Event.ToolStatus? = .succeeded, exit: Int? = nil
  ) -> MirrorConversationItem {
    let start = Event.ToolStart(id: "t\(id)", name: "Bash", kind: kind, title: "step \(id)")
    let end = status.map { Event.ToolEnd(id: "t\(id)", status: $0, exitCode: exit) }
    return .tool(id: id, start: start, end: end, startedAt: nil, endedAt: nil)
  }

  private static func assistant(_ id: UInt64) -> MirrorConversationItem {
    .assistant(id: id, text: .init("text \(id)"), phase: nil, at: nil)
  }

  @Test func consecutiveToolsFoldIntoOneRowBetweenMessages() {
    let rows = MirrorChatRow.rows([
      Self.assistant(1), Self.tool(2), .reasoning(id: 3, durationMs: 2000, summary: nil), Self.tool(4, .read),
      Self.assistant(5), Self.tool(6),
    ])
    #expect(rows.map(\.id) == [1, 2, 5, 6])
    guard case .steps(let steps) = rows[1] else {
      Issue.record("expected a steps row")
      return
    }
    #expect(steps.toolCount == 2)
    #expect(steps.items.count == 3)
    #expect(steps.kinds == [.shell, .read])
    #expect(steps.running == nil)
  }

  @Test func failuresAndRunningToolsAreCounted() {
    let rows = MirrorChatRow.rows([
      Self.tool(1, end: .error), Self.tool(2, exit: 1), Self.tool(3), Self.tool(4, end: nil),
    ])
    guard case .steps(let steps) = rows.first else {
      Issue.record("expected a steps row")
      return
    }
    #expect(steps.failedCount == 2)
    #expect(steps.running?.id == "t4")
  }

  @Test func attentionAndLoneReasoningAreLeftOut() {
    let rows = MirrorChatRow.rows([
      .attention(id: 1, status: .init(state: .blocked), at: nil),
      .reasoning(id: 2, durationMs: 3000, summary: nil),
      Self.assistant(3),
    ])
    #expect(rows.map(\.id) == [3])
  }

  @Test func toolTitlesDropTheShellWrapper() {
    let wrapped = Event.ToolStart(id: "t", name: "exec", kind: .shell, title: "/bin/zsh -lc rg -n foo")
    #expect(MirrorToolKindStyle.title(wrapped) == "rg -n foo")
    let untitled = Event.ToolStart(id: "t", name: "Read", kind: .read, title: "")
    #expect(MirrorToolKindStyle.title(untitled) == "Read")
  }

  @MainActor @Test func fixtureConversationKeepsEveryMessageAndFoldsTools() throws {
    let session = MirrorUIFixture.conversationSession(fixture: "codex-review-1038", agent: "codex")
    let items = session.conversation.items
    let rows = MirrorChatRow.rows(items)
    let messages = items.filter { if case .assistant = $0 { true } else if case .user = $0 { true } else { false } }
    let messageRows = rows.filter { if case .item(let item) = $0 { item.isMessage } else { false } }
    #expect(messageRows.count == messages.count)
    #expect(rows.count < items.count)
  }
}

extension MirrorConversationItem {
  fileprivate var isMessage: Bool {
    switch self {
    case .assistant, .user: true
    default: false
    }
  }
}
