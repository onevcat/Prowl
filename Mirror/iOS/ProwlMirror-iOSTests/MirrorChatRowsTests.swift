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

  @Test func openPromptsLeaveTheChatAndAnsweredOnesShowOnce() {
    let open = Event.Prompt(id: "screen:1", kind: .question, title: "Which format?", freeform: false)
    var answered = open
    answered.outcome = .answered
    var transcript = Event.Prompt(
      id: "toolu_1", kind: .question, title: nil,
      questions: [.init(id: "0", question: "Which format?", multiSelect: false, options: [])], freeform: true)
    transcript.outcome = .answered
    let rows = MirrorChatRow.rows([
      .prompt(id: 1, prompt: open, resolved: nil, at: nil),
      .prompt(id: 2, prompt: open, resolved: answered, at: nil),
      .prompt(id: 3, prompt: transcript, resolved: transcript, at: nil),
      Self.assistant(4),
    ])
    #expect(rows.map(\.id) == [2, 4])
  }

  /// Two decisions with the same question are two rows; only the transcript's copy of a screen
  /// answer folds into it (089 review S4-R4).
  @Test func sameTitledDecisionsAllStayAndOnlyTheirCopiesFold() {
    func screen(_ id: String, _ outcome: Event.PromptOutcome) -> Event.Prompt {
      var prompt = Event.Prompt(id: id, kind: .permission, title: "Do you want to proceed?", freeform: false)
      prompt.outcome = outcome
      return prompt
    }
    var transcript = Event.Prompt(
      id: "toolu_1", kind: .question, title: nil,
      questions: [.init(id: "0", question: "Which format?", multiSelect: false, options: [])], freeform: true)
    transcript.outcome = .answered
    var question = Event.Prompt(id: "screen:q.3", kind: .question, title: "Which format?", freeform: false)
    question.outcome = .answered
    let rows = MirrorChatRow.rows([
      .prompt(id: 1, prompt: screen("screen:a.1", .allowed), resolved: screen("screen:a.1", .allowed), at: nil),
      .prompt(id: 2, prompt: screen("screen:b.2", .denied), resolved: screen("screen:b.2", .denied), at: nil),
      .prompt(id: 3, prompt: transcript, resolved: transcript, at: nil),
      .prompt(id: 4, prompt: question, resolved: question, at: nil),
    ])
    #expect(rows.map(\.id) == [1, 2, 4])
  }

  @MainActor @Test func theOpenScreenPromptIsTheNewestUnresolvedOne() {
    var store = MirrorConversationStore()
    let first = Event.Prompt(id: "screen:a", kind: .permission, title: "Proceed?", freeform: false)
    let second = Event.Prompt(id: "screen:b", kind: .question, title: "Which?", freeform: true)
    let transcript = Event.Prompt(id: "toolu_x", kind: .question, title: "Which?", freeform: true)
    var resolved = first
    resolved.outcome = .allowed
    store.apply(events: [
      .init(.promptOpened, .prompt(first), at: nil, source: .screen, sequence: 1),
      .init(.promptResolved, .prompt(resolved), at: nil, source: .screen, sequence: 2),
      .init(.promptOpened, .prompt(second), at: nil, source: .screen, sequence: 3),
      .init(.promptOpened, .prompt(transcript), at: nil, source: .transcript, sequence: 4),
    ], sequence: 4)
    #expect(store.openScreenPrompt?.id == "screen:b")
  }

  @Test func aScreenPromptAnswerReadsWhereItHappened() {
    let prompt = Event.Prompt(id: "screen:q", kind: .question, title: "Which?", freeform: false)
    var answered = prompt
    answered.outcome = .answered
    var store = MirrorConversationStore()
    store.apply(events: [
      .init(.promptOpened, .prompt(prompt), at: nil, source: .screen, sequence: 1),
      .init(.userMessage, .message(.init(text: .init("hi"))), at: nil, source: .transcript, sequence: 2),
      .init(.toolStarted, .toolStart(.init(id: "t", name: "Bash", kind: .shell, title: "ls")), at: nil,
        source: .transcript, sequence: 3),
      .init(.promptResolved, .prompt(answered), at: nil, source: .screen, sequence: 4),
      .init(.toolCompleted, .toolEnd(.init(id: "t", status: .succeeded)), at: nil, source: .transcript, sequence: 5),
    ], sequence: 5)
    #expect(store.items.map(\.id) == [2, 3, 4])
    guard case .tool(_, _, let end, _, _) = store.items[1] else {
      Issue.record("expected the tool to stay merged")
      return
    }
    #expect(end?.status == .succeeded)
  }

  @Test func pagingKeepsAToolRunWholeAcrossThePageBoundary() {
    var items: [MirrorConversationItem] = (1...121).map { Self.tool(UInt64($0), end: $0 == 1 ? .error : .succeeded) }
    var page = MirrorChatRow.page(items, limit: 120)
    guard case .steps(let steps) = page.rows.first else {
      Issue.record("expected a steps row")
      return
    }
    #expect(steps.id == 1 && steps.toolCount == 121 && steps.failedCount == 1)
    #expect(page.hidden == 0)
    items.append(Self.assistant(122))
    page = MirrorChatRow.page(items, limit: 120)
    #expect(page.rows.first?.id == 1)
  }

  @MainActor @Test func aToolDetailReadsTheCallsCurrentState() {
    var store = MirrorConversationStore()
    store.apply(events: [
      .init(.toolStarted, .toolStart(.init(id: "t", name: "Bash", kind: .shell, title: "make")), at: nil,
        source: .transcript, sequence: 1)
    ], sequence: 1)
    #expect(store.tool(id: 1)?.end == nil)
    store.apply(events: [
      .init(.toolCompleted, .toolEnd(.init(id: "t", status: .succeeded, output: .init("BUILD SUCCEEDED"))), at: nil,
        source: .transcript, sequence: 2)
    ], sequence: 2)
    #expect(store.tool(id: 1)?.end?.output?.text == "BUILD SUCCEEDED")
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
