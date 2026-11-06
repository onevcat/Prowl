import Foundation

/// The chat as rows (docs-ai 089 S2): messages stay their own rows, and every run of tool
/// calls and reasoning between two messages folds into one quiet "steps" row, so the agent's
/// words stay in view. Attention items are left out: the pane shows the blocked state above
/// the composer instead.
nonisolated enum MirrorChatRow: Identifiable, Equatable, Sendable {
  case item(MirrorConversationItem)
  case steps(Steps)

  var id: UInt64 {
    switch self {
    case .item(let item): item.id
    case .steps(let steps): steps.id
    }
  }

  struct Steps: Equatable, Sendable {
    /// The first item's id, stable while the run grows.
    let id: UInt64
    var items: [MirrorConversationItem]

    var tools: [MirrorConversationItem] { items.filter(\.isTool) }
    var toolCount: Int { tools.count }
    var failedCount: Int {
      tools.count { item in
        if case .tool(_, _, let end?, _, _) = item { return end.status != .succeeded || (end.exitCode ?? 0) != 0 }
        return false
      }
    }
    /// The tool still running, if any; the row shows it while the agent works.
    var running: MirrorConversationEvent.ToolStart? {
      for item in tools.reversed() {
        if case .tool(_, let start, nil, _, _) = item, start.kind != .question { return start }
      }
      return nil
    }
    var kinds: [MirrorConversationEvent.ToolKind] {
      var seen: [MirrorConversationEvent.ToolKind] = []
      for item in tools {
        if case .tool(_, let start, _, _, _) = item, !seen.contains(start.kind) { seen.append(start.kind) }
      }
      return seen
    }
  }

  static func rows(_ items: some Sequence<MirrorConversationItem>) -> [MirrorChatRow] {
    var rows: [MirrorChatRow] = []
    let items = Array(items)
    let absorbed = transcriptCopiesOfScreenAnswers(items)
    for item in items {
      if absorbed.contains(item.id) { continue }
      switch item {
      case .attention, .prompt(_, _, nil, _):
        // Shown once above the composer: the blocked strip, or the prompt panel (docs-ai 089 S4).
        continue
      case .tool, .reasoning:
        if case .steps(var steps) = rows.last {
          steps.items.append(item)
          rows[rows.count - 1] = .steps(steps)
        } else {
          rows.append(.steps(.init(id: item.id, items: [item])))
        }
      default:
        rows.append(.item(item))
      }
    }
    // A run of reasoning alone is not worth a row of its own.
    return rows.filter { row in
      if case .steps(let steps) = row { return steps.toolCount > 0 }
      return true
    }
  }
}

extension MirrorChatRow {
  /// The screen and the transcript can both report one answered question. A screen answer
  /// absorbs at most one transcript copy with the same question, and only between the same two
  /// messages, where its own copy lands; the screen line stays, where the answer happened.
  /// Separate decisions, and answers from another turn, keep their rows (089 review S4-R4).
  nonisolated static func transcriptCopiesOfScreenAnswers(_ items: [MirrorConversationItem]) -> Set<UInt64> {
    var absorbed: Set<UInt64> = []
    var segment: [MirrorConversationItem] = []
    func pair() {
      var screenAnswers: [String: Int] = [:]
      for item in segment {
        if let title = item.resolvedPromptTitle(screen: true) { screenAnswers[title, default: 0] += 1 }
      }
      for item in segment {
        guard let title = item.resolvedPromptTitle(screen: false), let count = screenAnswers[title], count > 0
        else { continue }
        screenAnswers[title] = count - 1
        absorbed.insert(item.id)
      }
      segment.removeAll()
    }
    for item in items {
      if case .user = item { pair() } else if case .assistant = item { pair() } else { segment.append(item) }
    }
    pair()
    return absorbed
  }

  /// The newest `limit` rows and how many rows are hidden before them. Grouping runs over every
  /// item first, so a run of tool calls keeps its identity and its counts across pages.
  nonisolated static func page(_ items: [MirrorConversationItem], limit: Int) -> (rows: ArraySlice<MirrorChatRow>, hidden: Int) {
    let all = rows(items)
    return (all.suffix(limit), max(0, all.count - limit))
  }
}

extension MirrorConversationStore {
  /// The current start and end of a tool call, for a details sheet that stays open while it runs.
  nonisolated func tool(id: UInt64) -> (start: MirrorConversationEvent.ToolStart, end: MirrorConversationEvent.ToolEnd?)? {
    for item in items.reversed() {
      if case .tool(let itemID, let start, let end, _, _) = item, itemID == id { return (start, end) }
    }
    return nil
  }
}

extension MirrorConversationItem {
  nonisolated var isTool: Bool {
    if case .tool = self { true } else { false }
  }

  /// The question of a resolved prompt from the screen (`screen: true`) or from the transcript.
  nonisolated fileprivate func resolvedPromptTitle(screen: Bool) -> String? {
    guard case .prompt(_, let prompt, _?, _) = self, prompt.id.hasPrefix("screen:") == screen else { return nil }
    return prompt.title ?? prompt.questions?.first?.question
  }
}
