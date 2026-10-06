import Foundation

enum DevinScreenProfile {
  enum RuleID {
    nonisolated static let directoryTrust = AgentScreenRuleID("devin.directoryTrust")
    nonisolated static let selection = AgentScreenRuleID("devin.selection")
    nonisolated static let workingFooter = AgentScreenRuleID("devin.workingFooter")
    nonisolated static let emptyComposer = AgentScreenRuleID("devin.emptyComposer")
    nonisolated static let all = [directoryTrust, selection, workingFooter, emptyComposer]
  }

  nonisolated static func detect(in snapshot: AgentScreenSnapshot) -> AgentScreenDetection {
    let lines = snapshot.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
    // Menus replace the composer. Require live navigation chrome at the bottom so
    // permission examples and old dialogs in the conversation do not report Blocked.
    if let footer = lines.last, isSelectionFooter(footer),
      lines.contains(where: { $0.hasPrefix("❭ ") })
    {
      let isTrust =
        lines.contains("✱ Do you trust the authors of this directory?")
        && lines.contains(where: { $0.contains("Yes, trust") })
        && lines.contains(where: { $0.contains("No, exit") })
      return .init(
        state: .blocked, reason: .matched(isTrust ? RuleID.directoryTrust : RuleID.selection))
    }
    if let composer = composerIndex(in: lines) {
      // The activity footer immediately precedes the top composer separator.
      let before = lines.prefix(composer - 1).suffix(2)
      if before.contains(where: isWorkingFooter) {
        return .init(state: .working, reason: .matched(RuleID.workingFooter))
      }
      if composerIsEmpty(lines: lines, index: composer) {
        return .init(state: .idle, reason: .matched(RuleID.emptyComposer))
      }
    }
    return .init(state: .idle, reason: .noRuleMatched)
  }

  nonisolated static func composerContents(in snapshot: AgentScreenSnapshot) -> String? {
    let lines = snapshot.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
    guard let index = composerIndex(in: lines) else { return nil }
    if composerIsEmpty(lines: lines, index: index) { return "" }
    guard let end = lines.indices.last(where: { isSeparator(lines[$0]) }) else { return nil }
    return
      ([String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces)]
      + Array(lines[(index + 1)..<end])).joined(separator: "\n")
  }

  private nonisolated static func composerIsEmpty(lines: [String], index: Int) -> Bool {
    isSeparator(lines[index + 1])
      && ["❭", "❭ Ask Devin to build features, fix bugs, or work on your code"].contains(
        lines[index])
  }

  private nonisolated static func composerIndex(in lines: [String]) -> Int? {
    guard let index = lines.lastIndex(where: { $0 == "❭" || $0.hasPrefix("❭ ") }),
      index > 0, index + 2 < lines.count,
      isSeparator(lines[index - 1]),
      let end = lines.indices.last(where: { isSeparator(lines[$0]) }), end > index,
      lines.count - end <= 3
    else { return nil }
    return index
  }

  private nonisolated static func isSeparator(_ line: String) -> Bool {
    line.count >= 3 && line.allSatisfy { $0 == "─" }
  }

  private nonisolated static func isSelectionFooter(_ line: String) -> Bool {
    let lower = line.lowercased()
    return (line.contains("↑") || line.contains("↓")) && lower.contains("esc")
      && (lower.contains("select") || lower.contains("choose") || lower.contains("confirm"))
  }

  private nonisolated static func isWorkingFooter(_ line: String) -> Bool {
    guard line.contains("(esc twice to interrupt)"), line.contains(" · ") else { return false }
    let activity = line.drop(while: {
      $0.isWhitespace || $0.unicodeScalars.allSatisfy { (0x2800...0x28FF).contains($0.value) }
    })
    return ["Thinking · ", "Running tools · ", "Typing · "].contains { activity.hasPrefix($0) }
  }
}
