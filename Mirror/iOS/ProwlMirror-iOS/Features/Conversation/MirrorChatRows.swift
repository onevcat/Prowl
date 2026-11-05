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
    // The screen and the transcript can both report one question once it is answered; one
    // line for it is enough.
    var resolvedTitles: Set<String> = []
    for item in items {
      if case .prompt(_, let prompt, _?, _) = item, let title = prompt.title ?? prompt.questions?.first?.question {
        guard resolvedTitles.insert(title).inserted else { continue }
      }
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

extension MirrorConversationItem {
  nonisolated var isTool: Bool {
    if case .tool = self { true } else { false }
  }
}
