import Foundation

enum ClaudeScreenProfile {
  enum RuleID {
    nonisolated static let viewer = AgentScreenRuleID("claude.viewer")
    nonisolated static let blockedPrompt = AgentScreenRuleID("claude.blockedPrompt")
    nonisolated static let spinner = AgentScreenRuleID("claude.spinner")
    nonisolated static let elapsedStatus = AgentScreenRuleID("claude.elapsedStatus")
    nonisolated static let backgroundWork = AgentScreenRuleID("claude.backgroundWork")
    nonisolated static let idleComposer = AgentScreenRuleID("claude.idleComposer")

    // Keep exhaustive so prefix and uniqueness tests cover every emitted ID.
    nonisolated static let all = [
      viewer,
      blockedPrompt,
      spinner,
      elapsedStatus,
      backgroundWork,
      idleComposer,
    ]
  }

  nonisolated static func detect(in snapshot: AgentScreenSnapshot) -> AgentScreenDetection {
    let regions = ClaudeScreenRegions(snapshot: snapshot)

    if hasViewerChrome(regions) {
      return AgentScreenDetection(state: .unknown, reason: .matched(RuleID.viewer))
    }
    if hasBlockedPrompt(regions) {
      return AgentScreenDetection(state: .blocked, reason: .matched(RuleID.blockedPrompt))
    }
    if hasSpinnerActivity(regions.liveStatus) {
      return AgentScreenDetection(state: .working, reason: .matched(RuleID.spinner))
    }
    if hasElapsedStatusLine(regions.liveStatus) {
      return AgentScreenDetection(state: .working, reason: .matched(RuleID.elapsedStatus))
    }
    if hasBackgroundAgentWait(regions.liveStatus)
      || regions.belowPromptLines.joined(separator: "\n").lowercased().contains("agents done")
    {
      return AgentScreenDetection(state: .working, reason: .matched(RuleID.backgroundWork))
    }
    if regions.hasIdleComposer {
      return AgentScreenDetection(state: .idle, reason: .matched(RuleID.idleComposer))
    }
    return AgentScreenDetection(state: .idle, reason: .noRuleMatched)
  }

  /// Raw current interaction text for an actionable blocked screen. Keep the
  /// rendered choices and keyboard hints intact rather than inventing option fields.
  nonisolated static func blockerText(in snapshot: AgentScreenSnapshot) -> String? {
    let regions = ClaudeScreenRegions(snapshot: snapshot)
    guard hasBlockedPrompt(regions) else { return nil }
    let lines =
      regions.currentInteractionLines.isEmpty ? Array(snapshot.lines.suffix(18)) : regions.currentInteractionLines
    return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
  }

  nonisolated private static func hasViewerChrome(_ regions: ClaudeScreenRegions) -> Bool {
    if regions.bottomChromeLines.contains(where: { line in
      line.contains("⌕ Search…") || line.lowercased().contains("ctrl+r to toggle")
    }) {
      return true
    }

    let lower = regions.bottomViewerLines.joined(separator: "\n").lowercased()
    return lower.contains("⌕ filter history")
      && lower.contains("↑/↓ to nav")
      && lower.contains("enter to use")
      && lower.contains("esc to cancel")
      && lower.contains("ctrl+s to scope")
  }

  nonisolated private static func hasBlockedPrompt(_ regions: ClaudeScreenRegions) -> Bool {
    let lower = regions.currentInteractionLower
    if lower.contains("do you want to proceed?")
      || lower.contains("would you like to proceed?")
      || lower.contains("waiting for permission")
      || lower.contains("do you want to allow this connection?")
      || lower.contains("tab to amend")
      || lower.contains("ctrl+e to explain")
      || lower.contains("chat about this")
      || lower.contains("review your answers")
      || lower.contains("skip interview and plan immediately")
      || hasWorkspaceTrustPrompt(lower)
    {
      return true
    }
    return hasConfirmationPrompt(lower)
      || (hasSelectionPrompt(regions.currentInteractionLines)
        && hasYesNoChoice(regions.currentInteractionLines))
  }

  // Newer Claude releases render this initial gate as plain "No, exit" /
  // "Yes, I trust this folder" rows instead of a numbered menu. Keep the full prompt
  // signature so the user entering one of those phrases into the composer
  // cannot be mistaken for a live blocker.
  nonisolated private static func hasWorkspaceTrustPrompt(_ lower: String) -> Bool {
    lower.contains("quick safety check:")
      && lower.contains("claude code'll be able to read, edit, and execute files here.")
      && lower.contains("no, exit")
      && lower.contains("yes, i trust this folder")
      && lower.contains("enter to confirm")
  }

  nonisolated private static func hasSelectionPrompt(_ lines: [String]) -> Bool {
    lines.contains(where: isClaudeNumberedSelectionLine)
  }

  nonisolated private static func hasYesNoChoice(_ lines: [String]) -> Bool {
    lines.contains { line in
      let line = line.trimmingCharacters(in: .whitespaces)
      let option =
        line.hasPrefix("❯")
        ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        : line
      let trimmed = option.lowercased()
      return trimmed == "yes"
        || trimmed == "no"
        || trimmed.hasPrefix("1. yes")
        || trimmed.hasPrefix("2. no")
        || trimmed.hasPrefix("yes, and ")
        || trimmed.hasPrefix("no, and tell claude")
    }
  }

  // Claude's live status row is "● <label>… (<elapsed> · <detail>)". The label is
  // free text and is not always a single word — "Running gates and merge
  // lifecycle…" is as common as "Forging…" — so only the trailing ellipsis is
  // structural. The elapsed segment grows with the turn and becomes several
  // tokens once it passes a minute: "45s", "28m 34s", "1h 4m 2s". Both parts stay
  // strict about completeness so transcript prose such as "(1st attempt)" or
  // "(10seconds)" still cannot pass as a live status row.
  // Free-text labels contain parentheses — "Running tests (focused)…" — so the
  // elapsed segment is located from the END of the row. Candidate openings are
  // tried right to left, and the first one whose contents parse as a complete
  // elapsed segment wins. Anchoring at the first "(" instead would read
  // "focused)… (1m 38s" as the elapsed and reject a live row.
  nonisolated private static func hasElapsedStatusLine(_ content: String) -> Bool {
    claudeLogicalRows(content).contains { row in
      guard row.first == "●" else { return false }
      let body = row.dropFirst().trimmingCharacters(in: .whitespaces)

      for open in body.indices.reversed() where body[open] == "(" {
        let label = body[..<open].trimmingCharacters(in: .whitespaces)
        guard label.hasSuffix("…") else { continue }
        if hasCompleteElapsedSegment(body[body.index(after: open)...]) {
          return true
        }
      }
      return false
    }
  }

  // One or more "<digits><unit>" tokens separated by single spaces, terminated by
  // the closing paren or by the " · " that separates elapsed from the rest of the
  // row. A partial token ("10seconds", "1st") fails the terminator check.
  nonisolated private static func hasCompleteElapsedSegment(_ elapsed: Substring) -> Bool {
    var remainder = elapsed
    var tokenCount = 0

    while true {
      let digits = remainder.prefix(while: \.isNumber)
      guard !digits.isEmpty else { break }
      let afterDigits = remainder.dropFirst(digits.count)
      guard let unit = afterDigits.first, unit == "s" || unit == "m" || unit == "h" else { break }
      tokenCount += 1
      remainder = afterDigits.dropFirst()
      guard remainder.hasPrefix(" "), remainder.dropFirst().first?.isNumber == true else { break }
      remainder = remainder.dropFirst()
    }

    guard tokenCount > 0 else { return false }
    return remainder.hasPrefix(")") || remainder.hasPrefix(" · ")
  }

  // When Claude delegates to a background agent, its own turn ends first: the
  // spinner above the prompt is replaced by "✻ Waiting for 1 background agent to
  // finish". That row carries a spinner glyph but no "…", so hasSpinnerActivity
  // rejects it and the pane reports finished while the agent is still running.
  //
  // The agent switcher block below the input box ("⏺ main" plus one "◯" row per
  // agent) looks like a better signal but is not one. A subagent that returns
  // control while still awaiting collection keeps its row, with the elapsed value
  // frozen — a single screen cannot separate that from a running agent, so
  // matching the row shape would hold the pane at working after the work stopped.
  // The wait row is only painted while Claude is genuinely blocked on an agent,
  // and it is scoped to the live status region so a transcript quoting it cannot
  // trip the rule.
  nonisolated private static func hasBackgroundAgentWait(_ liveStatus: String) -> Bool {
    claudeLogicalRows(liveStatus).contains { row in
      guard let first = row.unicodeScalars.first, isAgentSpinnerScalar(first) else {
        return false
      }
      let lower = row.lowercased()
      return lower.contains("waiting for") && lower.contains("background agent")
    }
  }
}

private struct ClaudeScreenRegions: Sendable {
  let currentInteractionLines: [String]
  let currentInteractionLower: String
  let liveStatus: String
  let belowPromptLines: [String]
  let bottomChromeLines: [String]
  let bottomViewerLines: [String]
  let hasIdleComposer: Bool

  nonisolated init(snapshot: AgentScreenSnapshot) {
    let lines = snapshot.lines
    let promptIndex = lines.lastIndex(where: { $0.contains("❯") })
    let currentInteractionLines = Self.currentInteractionLines(
      screenLines: lines,
      promptIndex: promptIndex
    )
    self.currentInteractionLines = currentInteractionLines
    self.currentInteractionLower = currentInteractionLines.joined(separator: "\n").lowercased()
    // Reconstruct rows before selecting the region. Counting in physical lines
    // drops the head of any row that wraps onto three or more continuations,
    // and the head is what carries the "●" or spinner glyph the rules key on.
    // Widths that narrow are reachable: a surface can be as few as five columns.
    //
    // The block is then bounded by shape, not by count. The TUI paints live
    // status as a trailing run of chrome-headed rows directly above the
    // composer, so rows are taken bottom-up while they keep that shape. A
    // fixed row count put an upper bound on the block — one extra queued "❯"
    // message or "⎿" tip row displaced the live spinner and a working agent
    // read as idle — while stopping at the first transcript-shaped row keeps
    // a status row quoted inside a "⏺" block or prose from matching now that
    // Claude detection reads the full active screen.
    self.liveStatus = Self.liveStatusBlock(
      claudeLogicalRows(Self.contentAbovePrompt(screenLines: lines, promptIndex: promptIndex))
    )
    .joined(separator: "\n")
    self.belowPromptLines = Self.contentBelowPrompt(screenLines: lines, promptIndex: promptIndex)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let nonEmptyLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    self.bottomChromeLines = Array(nonEmptyLines.suffix(3))
    self.bottomViewerLines = Array(nonEmptyLines.suffix(5))
    self.hasIdleComposer = Self.hasIdleComposer(screenLines: lines, promptIndex: promptIndex)
  }

  nonisolated private static func liveStatusBlock(_ rows: [String]) -> ArraySlice<String> {
    var start = rows.endIndex
    while start > rows.startIndex {
      if isClaudeLiveChromeRow(rows[start - 1]) {
        start -= 1
        continue
      }
      guard let head = queuedMessageHeadIndex(above: start - 1, in: rows) else { break }
      start = head
    }
    return rows[start...]
  }

  // A prose row sits inside the live block only as a queued-message body
  // paragraph: a blank line inside a queued "❯" message detaches the paragraph
  // from its head row, so it surfaces as an unmarked row and would otherwise
  // end the block, demoting the spinner above to history while the agent is
  // still working. Body paragraphs hang directly under their head, so the
  // prose run counts as queued body only when the first row-starting or
  // chrome row above it is a "❯" head. Anything else on top — a "⏺" block, a
  // border, or non-queued chrome such as a quoted spinner — means the prose
  // is transcript text, which still ends the block.
  nonisolated private static func queuedMessageHeadIndex(above proseIndex: Int, in rows: [String]) -> Int? {
    var index = proseIndex
    while index > rows.startIndex {
      let row = rows[index - 1]
      if row.first == "❯" { return index - 1 }
      if isClaudeLiveChromeRow(row) || claudeRowStartsNewRow(row) { return nil }
      index -= 1
    }
    return nil
  }

  nonisolated private static func currentInteractionLines(
    screenLines: [String],
    promptIndex: Int?
  ) -> [String] {
    guard let promptIndex else {
      return Array(screenLines.suffix(18))
    }
    let isWorkspaceTrustChoice = isClaudeWorkspaceTrustChoiceLine(screenLines[promptIndex])
    guard isClaudeNumberedSelectionLine(screenLines[promptIndex]) || isWorkspaceTrustChoice else {
      return []
    }
    // The first-launch safety copy wraps before the choices. Keep its full
    // signature when the new unnumbered menu appears; numbered menus retain
    // the narrower interaction window used to reject stale transcript text.
    let lineLimit = isWorkspaceTrustChoice ? 18 : 10
    let lowerBound = max(screenLines.startIndex, promptIndex - lineLimit)
    return Array(screenLines[lowerBound..<screenLines.endIndex])
  }

  nonisolated private static func contentAbovePrompt(
    screenLines: [String],
    promptIndex: Int?
  ) -> String {
    guard let promptIndex else {
      return screenLines.joined(separator: "\n")
    }
    let borderIndex = screenLines[..<promptIndex].lastIndex(where: isBoxBorderLine)
    return screenLines[..<(borderIndex ?? promptIndex)].joined(separator: "\n")
  }

  nonisolated private static func contentBelowPrompt(
    screenLines: [String],
    promptIndex: Int?
  ) -> String {
    guard let promptIndex else { return "" }
    let startIndex = screenLines.index(after: promptIndex)
    guard startIndex < screenLines.endIndex else { return "" }
    return screenLines[startIndex...].joined(separator: "\n")
  }

  nonisolated private static func hasIdleComposer(
    screenLines: [String],
    promptIndex: Int?
  ) -> Bool {
    guard let promptIndex, promptIndex > screenLines.startIndex else { return false }
    let nextIndex = screenLines.index(after: promptIndex)
    guard nextIndex < screenLines.endIndex else { return false }
    return isBoxBorderLine(screenLines[screenLines.index(before: promptIndex)])
      && isBoxBorderLine(screenLines[nextIndex])
  }
}

// Claude wraps a row too wide for the pane onto indented continuation lines —
// observed at 40 columns on 2.1.225:
//
//   "✻ Waiting for 1 background agent to"
//   "  finish"
//
// Narrow split panes are ordinary, so every rule that reads a row has to see the
// logical row rather than the first physical one, and so does the region that
// selects which rows the rules see. Only an adjacent line indented past its head
// and starting with ordinary text is a continuation: a line opening with its own
// marker starts a new row, which keeps this from swallowing the whole region and
// inventing rows that were never on screen.
//
// Rows arrive already trimmed and unindented, so running this over its own output
// returns that output unchanged.
nonisolated private func claudeLogicalRows(_ content: String) -> [String] {
  var rows: [String] = []
  var current: String?
  var headIndent = 0

  for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      if let row = current { rows.append(row) }
      current = nil
      continue
    }
    let indent = line.prefix(while: { $0 == " " }).count

    if current != nil, indent > headIndent, !claudeRowStartsNewRow(trimmed) {
      current?.append(" ")
      current?.append(trimmed)
      continue
    }
    if let row = current { rows.append(row) }
    current = trimmed
    headIndent = indent
  }
  if let row = current { rows.append(row) }
  return rows
}

nonisolated private func claudeRowStartsNewRow(_ trimmed: String) -> Bool {
  guard let first = trimmed.unicodeScalars.first else { return false }
  if isAgentSpinnerScalar(first) { return true }
  return "●⏺◯⎿❯─-".unicodeScalars.contains(first)
}

// Rows the TUI paints below the transcript while a turn is live: the spinner
// or "●" status row, "⎿" attachments (todo lists, tips), queued "❯" messages,
// todo checkboxes when they surface as their own rows, and right-aligned
// chrome such as "◉ xhigh · /effort" (whose head is a spinner scalar). "⏺"
// transcript blocks, "◯" agent-switcher rows, prose, and borders end the live
// block: everything above them is history, however status-shaped it looks.
nonisolated private func isClaudeLiveChromeRow(_ row: String) -> Bool {
  guard let first = row.unicodeScalars.first else { return false }
  if isAgentSpinnerScalar(first) { return true }
  return "●⎿❯◻☐✔✘".unicodeScalars.contains(first)
}

nonisolated private func isClaudeNumberedSelectionLine(_ line: String) -> Bool {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  guard trimmed.first == "❯" else { return false }
  let option = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
  return isNumberedChoice(option)
}

nonisolated private func isClaudeWorkspaceTrustChoiceLine(_ line: String) -> Bool {
  let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
  guard trimmed.hasPrefix("❯") else { return false }
  let option = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
  return option == "no, exit" || option == "yes, i trust this folder"
}

nonisolated private func isBoxBorderLine(_ line: String) -> Bool {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  guard trimmed.count >= 3 else { return false }
  return trimmed.allSatisfy { $0 == "─" || $0 == "-" }
}
