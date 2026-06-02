import Foundation

nonisolated let agentDetectionRecentLineLimit = 24

extension DetectedAgent {
  nonisolated func detectState(in screen: String) -> AgentRawState {
    let screen = agentDetectionRecentText(screen, limit: agentDetectionRecentLineLimit)
    switch self {
    case .pi:
      return detectPi(screen)
    case .claude:
      return detectClaude(screen)
    case .codex:
      return detectCodex(screen)
    case .gemini:
      return detectGemini(screen)
    case .cursor:
      return detectCursor(screen)
    case .cline:
      return detectCline(screen)
    case .opencode:
      return detectOpenCode(screen)
    case .copilot:
      return detectCopilot(screen)
    case .kimi:
      return detectKimi(screen)
    case .droid:
      return detectDroid(screen)
    case .amp:
      return detectAmp(screen)
    }
  }
}

nonisolated func agentDetectionRecentText(_ content: String, limit: Int) -> String {
  let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  var remainingNonBlankLines = limit
  var startIndex = lines.startIndex

  for index in lines.indices.reversed() {
    guard !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else {
      continue
    }
    remainingNonBlankLines -= 1
    if remainingNonBlankLines == 0 {
      startIndex = index
      break
    }
  }

  return lines[startIndex...].joined(separator: "\n")
}

nonisolated private func detectPi(_ content: String) -> AgentRawState {
  content.contains("Working...") ? .working : .idle
}

nonisolated private func detectClaude(_ content: String) -> AgentRawState {
  let lower = content.lowercased()

  if content.contains("⌕ Search…") || lower.contains("ctrl+r to toggle") {
    return .idle
  }
  let currentInteraction = claudeCurrentInteractionRegion(content)
  if hasClaudeBlockedPrompt(content: currentInteraction, lower: currentInteraction.lowercased()) {
    return .blocked
  }

  let above = contentAbovePromptBox(content)
  let aboveLower = above.lowercased()
  if aboveLower.contains("esc to interrupt") || aboveLower.contains("ctrl+c to interrupt") {
    return .working
  }
  if hasSpinnerActivity(above) {
    return .working
  }
  return .idle
}

nonisolated private func detectCodex(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  if lower.contains("press enter to confirm or esc to cancel")
    || lower.contains("enter to submit answer")
    || lower.contains("allow command?")
    || lower.contains("[y/n]")
    || lower.contains("yes (y)")
    || hasConfirmationPrompt(lower)
  {
    return .blocked
  }
  if hasInterruptPattern(lower) || hasCodexWorkingHeader(content) {
    return .working
  }
  return .idle
}

nonisolated private func detectGemini(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  if lower.contains("waiting for user confirmation")
    || content.contains("│ Apply this change")
    || content.contains("│ Allow execution")
    || content.contains("│ Do you want to proceed")
    || hasConfirmationPrompt(lower)
  {
    return .blocked
  }
  if lower.contains("esc to cancel") {
    return .working
  }
  return .idle
}

nonisolated private func detectCursor(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  if lower.contains("workspace trust required")
    || lower.contains("trust this workspace")
    || hasCursorPermissionPrompt(content: content, lower: lower)
  {
    return .blocked
  }
  if lower.contains("trusting workspace") || lower.contains("ctrl+c to stop") || hasCursorSpinner(content) {
    return .working
  }
  return .idle
}

nonisolated private func detectCline(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  if lower.contains("let cline use this tool")
    || ((lower.contains("[act mode]") || lower.contains("[plan mode]")) && lower.contains("yes"))
    || hasClineNumberedChoicePrompt(content)
  {
    return .blocked
  }
  if hasInterruptPattern(lower) {
    return .working
  }
  return .idle
}

nonisolated private func detectOpenCode(_ content: String) -> AgentRawState {
  if content.contains("△ Permission required")
    || hasOpenCodeQuestionPrompt(content)
  {
    return .blocked
  }
  if hasInterruptPattern(content.lowercased()) {
    return .working
  }
  return .idle
}

nonisolated private func detectCopilot(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  if lower.contains("│ do you want")
    || (lower.contains("confirm with") && lower.contains("enter"))
  {
    return .blocked
  }
  if lower.contains("esc to cancel") {
    return .working
  }
  return .idle
}

nonisolated private func detectKimi(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  let blockedPatterns = [
    "allow?", "confirm?", "approve?", "proceed?", "[y/n]", "(y/n)",
  ]
  if blockedPatterns.contains(where: lower.contains)
    || hasConfirmationPrompt(lower)
    || hasKimiApprovalPanel(content: content, lower: lower)
  {
    return .blocked
  }

  let workingPatterns = [
    "thinking", "processing", "generating", "waiting for response", "ctrl+c to cancel", "ctrl-c to cancel",
  ]
  if workingPatterns.contains(where: lower.contains)
    || hasKimiMoonSpinner(content)
    || hasKimiToolSpinner(content: content, lower: lower)
  {
    return .working
  }
  return .idle
}

nonisolated private func detectDroid(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  let hasExecute = content.contains("EXECUTE")
  let hasSelectionChrome =
    lower.contains("enter to select")
    || lower.contains("↑↓ to navigate")
    || lower.contains("esc to cancel")
  let hasSelectionOptions =
    lower.contains("> yes, allow")
    || lower.contains("> no, cancel")

  if hasExecute && (hasSelectionChrome || hasSelectionOptions) {
    return .blocked
  }
  if hasSelectionChrome && hasSelectionOptions {
    return .blocked
  }
  if hasDroidSpinner(content) || lower.contains("esc to stop") {
    return .working
  }
  return .idle
}

nonisolated private func detectAmp(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  let hasWaitingForApproval = lower.contains("waiting for approval")
  let hasApprovalHeader =
    lower.contains("invoke tool")
    || lower.contains("run this command?")
    || lower.contains("allow editing file:")
    || lower.contains("allow creating file:")
    || lower.contains("confirm tool call")
  let hasApprovalActions =
    lower.contains("approve")
    && (lower.contains("allow all for this session")
      || lower.contains("allow all for every session")
      || lower.contains("allow file for every session")
      || lower.contains("deny with feedback"))

  if hasApprovalActions && (hasWaitingForApproval || hasApprovalHeader) {
    return .blocked
  }
  if lower.contains("esc to cancel") {
    return .working
  }
  return .idle
}

nonisolated private func contentAbovePromptBox(_ content: String) -> String {
  let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  guard let promptIndex = lines.lastIndex(where: { $0.contains("❯") }) else {
    return content
  }
  let borderIndex = lines[..<promptIndex].lastIndex(where: isBoxBorderLine)
  let endIndex = borderIndex ?? promptIndex
  return lines[..<endIndex].joined(separator: "\n")
}

nonisolated private func isBoxBorderLine(_ line: String) -> Bool {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  guard trimmed.count >= 3 else { return false }
  return trimmed.allSatisfy { $0 == "─" || $0 == "-" }
}

nonisolated private func claudeCurrentInteractionRegion(_ content: String) -> String {
  let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  guard let promptIndex = lines.lastIndex(where: { $0.contains("❯") }) else {
    return lines.suffix(18).joined(separator: "\n")
  }

  let lowerBound = max(lines.startIndex, promptIndex - 10)
  return lines[lowerBound..<lines.endIndex].joined(separator: "\n")
}

nonisolated private func hasClaudeBlockedPrompt(content: String, lower: String) -> Bool {
  if lower.contains("do you want to proceed?")
    || lower.contains("would you like to proceed?")
    || lower.contains("waiting for permission")
    || lower.contains("do you want to allow this connection?")
    || lower.contains("tab to amend")
    || lower.contains("ctrl+e to explain")
    || lower.contains("chat about this")
    || lower.contains("review your answers")
    || lower.contains("skip interview and plan immediately")
  {
    return true
  }
  return hasConfirmationPrompt(lower)
    || (hasClaudeSelectionPrompt(content) && hasClaudeYesNoChoice(content))
}

nonisolated private func hasClaudeSelectionPrompt(_ content: String) -> Bool {
  content.split(separator: "\n").contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("❯")
      && trimmed.contains(".")
      && trimmed.contains(where: \.isNumber)
  }
}

nonisolated private func hasClaudeYesNoChoice(_ content: String) -> Bool {
  content.split(separator: "\n").contains { line in
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

nonisolated private func hasCursorPermissionPrompt(content: String, lower: String) -> Bool {
  if lower.contains("(y) (enter)") {
    return true
  }

  let hasPermissionHeader =
    lower.contains("run this command?")
    || lower.contains("run command?")
    || lower.contains("not in allowlist")
    || lower.contains("to allowlist?")
    || lower.contains("allow execution")
  guard hasPermissionHeader else { return false }

  let hasConfirmAction = content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
    guard trimmed.contains("(y)") else { return false }
    return trimmed.contains("run") || trimmed.contains("allow")
  }
  let hasCancelAction =
    lower.contains("skip (esc or n)")
    || lower.contains("keep (n)")

  return hasConfirmAction || hasCancelAction
}

nonisolated private func hasClineNumberedChoicePrompt(_ content: String) -> Bool {
  content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
    guard let suffix = line.range(of: " or type)") else { return false }
    let prefix = line[..<suffix.lowerBound]
    guard let openParen = prefix.lastIndex(of: "(") else { return false }
    let between = prefix[prefix.index(after: openParen)...]
    return between.contains("-") && between.allSatisfy { $0.isNumber || $0 == "-" }
  }
}

nonisolated private func hasKimiApprovalPanel(content: String, lower: String) -> Bool {
  lower.contains("requesting approval")
    || (lower.contains("approve once") && lower.contains("approve for this session") && lower.contains("reject"))
    || (content.contains("─ approval") && content.contains("↵ confirm"))
}

nonisolated private func hasKimiMoonSpinner(_ content: String) -> Bool {
  let moonSpinners: Set<Character> = ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"]
  return content.contains { moonSpinners.contains($0) }
}

nonisolated private func hasKimiToolSpinner(content: String, lower: String) -> Bool {
  guard lower.contains("using ") else { return false }
  return content.split(separator: "\n").contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.unicodeScalars.first else { return false }
    return (0x2800...0x28FF).contains(Int(first.value))
  }
}

nonisolated private func hasConfirmationPrompt(_ lower: String) -> Bool {
  guard
    let range = lower.range(of: "do you want") ?? lower.range(of: "would you like")
  else {
    return false
  }
  let after = lower[range.lowerBound...]
  return after.contains("yes") || after.contains("❯")
}

nonisolated private func hasInterruptPattern(_ lower: String) -> Bool {
  lower.contains("esc to interrupt")
    || lower.contains("ctrl+c to interrupt")
    || (lower.contains("esc") && lower.contains("interrupt"))
}

nonisolated private func hasCodexWorkingHeader(_ content: String) -> Bool {
  content.split(separator: "\n").contains { line in
    line.trimmingCharacters(in: .whitespaces).hasPrefix("• Working (")
  }
}

nonisolated private func hasSpinnerActivity(_ content: String) -> Bool {
  let spinnerScalars: Set<UnicodeScalar> = [
    "·", "✱", "✲", "✳", "✴", "✵", "✶", "✷", "✸", "✹", "✺", "✻", "✼", "✽", "✾", "✿",
    "❀", "❁", "❂", "❃", "❇", "❈", "❉", "❊", "❋", "✢", "✣", "✤", "✥", "✦", "✧", "✨",
    "⊛", "⊕", "⊙", "◉", "◎", "◍", "⁂", "⁕", "※", "⍟", "☼", "★", "☆",
  ]
  return content.split(separator: "\n").contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.unicodeScalars.first else { return false }
    let rest = String(trimmed.unicodeScalars.dropFirst())
    return spinnerScalars.contains(first)
      && rest.hasPrefix(" ")
      && rest.contains("…")
      && rest.contains(where: \.isLetter)
  }
}

nonisolated private func hasCursorSpinner(_ content: String) -> Bool {
  content.split(separator: "\n").contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
    return (trimmed.hasPrefix("⬡") || trimmed.hasPrefix("⬢")) && trimmed.contains("ing")
  }
}

nonisolated private func hasDroidSpinner(_ content: String) -> Bool {
  content.split(separator: "\n").contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
    guard let first = trimmed.unicodeScalars.first else { return false }
    return (0x2800...0x28FF).contains(Int(first.value)) && trimmed.contains("esc to stop")
  }
}

nonisolated private func hasOpenCodeQuestionPrompt(_ content: String) -> Bool {
  let lower = content.lowercased()
  let hasEnterAction =
    lower.contains("enter confirm")
    || lower.contains("enter submit")
    || lower.contains("enter toggle")
  let hasQuestionNavigation =
    content.contains("↑↓ select")
    || content.contains("⇆ tab")

  return lower.contains("esc dismiss") && hasEnterAction && hasQuestionNavigation
}
