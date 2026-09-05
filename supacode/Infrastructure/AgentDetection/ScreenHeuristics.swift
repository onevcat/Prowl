import Foundation

nonisolated let agentDetectionRecentLineLimit = 24
nonisolated let piAgentDetectionRecentLineLimit = 32

extension DetectedAgent {
  nonisolated func detectState(in screen: String) -> AgentRawState {
    detectScreen(in: screen).state
  }

  /// The slice of the active screen this agent's detector consumes.
  ///
  /// Claude reads the full active screen: its rules are region-anchored (the
  /// live status block is walked bottom-up from the composer by row shape,
  /// blockers around the prompt, viewer chrome from the bottom lines), so a
  /// bottom-measured line budget added no false-positive guard — it only cut
  /// the live signal off when a long todo list plus a multi-line status line
  /// pushed the spinner row past the limit and a working agent read as idle.
  ///
  /// Every other detector keeps a bounded tail as its guard against transcript
  /// history. Pi retains 32 non-blank lines so pi-subagents' adaptive widget can
  /// keep its header and live job row together; the remaining detectors keep 24.
  /// For the legacy scanners the tail is load-bearing — they match with whole-text
  /// scans. Codex's structured profile anchors its windows inside the tail instead;
  /// it shares Claude's bounded-bottom exposure in principle and keeps the tail
  /// until its regions are bounded by shape the same way.
  nonisolated func detectionScreenText(from screen: String) -> String {
    switch self {
    case .claude:
      screen
    case .pi:
      agentDetectionRecentLines(screen, limit: piAgentDetectionRecentLineLimit)
    default:
      agentDetectionRecentText(screen)
    }
  }

  /// The one production entry point for building a profile snapshot. State
  /// detection and blocker extraction must read the same slice; going through
  /// this keeps a call site from pairing a profile with the wrong one.
  nonisolated func detectionSnapshot(from screen: String) -> AgentScreenSnapshot {
    AgentScreenSnapshot(text: detectionScreenText(from: screen))
  }

  nonisolated func detectScreen(in screen: String) -> AgentScreenDetection {
    let text = detectionScreenText(from: screen)
    let state: AgentRawState
    switch self {
    case .pi:
      state = detectPi(text)
    case .omp:
      state = detectOMP(text)
    case .claude:
      return ClaudeScreenProfile.detect(in: AgentScreenSnapshot(text: text))
    case .codex:
      return CodexScreenProfile.detect(in: AgentScreenSnapshot(text: text))
    case .gemini:
      state = detectGemini(text)
    case .cursor:
      state = detectCursor(text)
    case .cline:
      state = detectCline(text)
    case .opencode:
      state = detectOpenCode(text)
    case .copilot:
      state = detectCopilot(text)
    case .kimi:
      state = detectKimi(text)
    case .droid:
      state = detectDroid(text)
    case .amp:
      state = detectAmp(text)
    case .qoder:
      state = detectQoder(text)
    case .qwen:
      state = detectQwen(text)
    case .grok:
      state = detectGrok(text)
    }
    return AgentScreenDetection(state: state, reason: .legacyDetector)
  }
}

nonisolated func agentDetectionRecentText(_ content: String) -> String {
  agentDetectionRecentLines(content, limit: agentDetectionRecentLineLimit)
}

nonisolated func agentDetectionRecentLines(_ content: String, limit: Int) -> String {
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
  let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map {
    $0.trimmingCharacters(in: .whitespaces)
  }
  let liveFooterLines = lines.filter { !$0.isEmpty }.suffix(5)
  return lines.contains(where: isPiWorkingText)
    || liveFooterLines.contains(where: isPiFramedWorkingFooter)
    || hasPiRunningAsyncSubagentCard(lines)
    ? .working
    : .idle
}

nonisolated private func hasPiRunningAsyncSubagentCard(_ lines: [String]) -> Bool {
  if lines.contains(where: isPiAdaptiveAsyncSubagentRunningLine) {
    return true
  }
  guard lines.count >= 2 else { return false }

  return lines.indices.dropLast().contains { index in
    guard let headerName = piAsyncSubagentName(from: lines[index]) else { return false }
    return isPiAsyncSubagentJobLine(lines[index + 1], matching: headerName)
  }
}

nonisolated private func piAsyncSubagentName(from header: String) -> (name: String, isPrefix: Bool)? {
  let prefix = "async subagent "
  let suffix = " · background"
  guard header.hasPrefix(prefix) else { return nil }

  let title: Substring
  let isPrefix: Bool
  if header.hasSuffix(suffix) {
    title = header.dropFirst(prefix.count).dropLast(suffix.count)
    isPrefix = false
  } else {
    guard header.hasSuffix("…") else { return nil }
    let truncatedTitle = header.dropFirst(prefix.count).dropLast()
    if let separator = truncatedTitle.range(of: " ·") {
      title = truncatedTitle[..<separator.lowerBound]
      isPrefix = false
    } else {
      title = truncatedTitle
      isPrefix = true
    }
  }

  let components = title.split(separator: " ")
  let countToken = components.last
  let completeCount = countToken?.dropFirst().dropLast()
  let hasCompleteCount =
    countToken?.first == "("
    && countToken?.last == ")"
    && completeCount?.isEmpty == false
    && completeCount?.allSatisfy(\.isNumber) == true
  let partialCount = countToken?.dropFirst()
  let hasTruncatedCount =
    isPrefix
    && countToken?.first == "("
    && countToken?.last != ")"
    && partialCount?.allSatisfy(\.isNumber) == true
  let hasTrailingCount = hasCompleteCount || hasTruncatedCount
  let name = hasTrailingCount ? components.dropLast().joined(separator: " ") : String(title)
  let nameIsPrefix = isPrefix && !hasTrailingCount
  return name.contains(where: \.isLetter) ? (name, nameIsPrefix) : nil
}

nonisolated private func isPiAsyncSubagentJobLine(
  _ line: String,
  matching headerName: (name: String, isPrefix: Bool)
) -> Bool {
  guard let content = labeledBrailleSpinnerContent(line), content.hasPrefix(headerName.name) else { return false }
  if headerName.isPrefix {
    return true
  }

  let remainder = content.dropFirst(headerName.name.count)
  if remainder.isEmpty || remainder.hasPrefix(" ·") {
    return true
  }
  return [" [fresh]", " [fork]", " [mixed]"].contains { badge in
    remainder == badge || remainder.hasPrefix("\(badge) ·")
  }
}

nonisolated private func isPiAdaptiveAsyncSubagentRunningLine(_ line: String) -> Bool {
  guard let content = labeledBrailleSpinnerContent(line) else { return false }
  if content.hasSuffix("…") {
    let visiblePrefix = content.dropLast()
    if visiblePrefix.hasPrefix("subagents (") || visiblePrefix.hasPrefix("Async agents · ") {
      return true
    }
  }
  if content == "Async agents · background" {
    return true
  }
  if content.hasPrefix("Async agents · ") {
    return isPiProgressiveAsyncSummary(String(content.dropFirst("Async agents · ".count)))
  }
  return isPiSingleLineAsyncSummary(content)
}

nonisolated private func isPiProgressiveAsyncSummary(_ summary: String) -> Bool {
  let components = summary.split(separator: " ", maxSplits: 2)
  guard components.count == 3,
    let count = Int(components[0]),
    count > 0,
    components[1] == (count == 1 ? "agent" : "agents")
  else {
    return false
  }

  let state = components[2]
  if state == "running" {
    return true
  }
  guard state.hasPrefix("running, ") else { return false }
  return isPiAsyncCountStatus(state.dropFirst("running, ".count), expected: "queued")
}

nonisolated private func isPiSingleLineAsyncSummary(_ content: String) -> Bool {
  let prefix = "subagents ("
  guard content.hasPrefix(prefix), content.hasSuffix(")") else { return false }

  let summary = content.dropFirst(prefix.count).dropLast()
  let components = summary.split(separator: ",", omittingEmptySubsequences: false)
  guard let runningSummary = components.first else { return false }
  let running = runningSummary.split(separator: " ")
  guard running.count == 2, running[1] == "running" else { return false }

  let counts = running[0].split(separator: "/", omittingEmptySubsequences: false)
  guard counts.count == 2,
    let activeCount = Int(counts[0]),
    let totalCount = Int(counts[1]),
    activeCount > 0,
    totalCount >= activeCount
  else {
    return false
  }

  let terminalStates = ["queued", "failed", "stopped", "paused"]
  return components.dropFirst().allSatisfy { component in
    terminalStates.contains { state in
      isPiAsyncCountStatus(component.drop(while: \.isWhitespace), expected: state)
    }
  }
}

nonisolated private func isPiAsyncCountStatus(_ summary: Substring, expected: String) -> Bool {
  let components = summary.split(separator: " ")
  return components.count == 2
    && Int(components[0]).map { $0 > 0 } == true
    && components[1] == Substring(expected)
}

nonisolated private func detectOMP(_ content: String) -> AgentRawState {
  if hasOMPAskPrompt(content) {
    return .blocked
  }
  return hasOMPWorkingLine(content) ? .working : .idle
}

nonisolated private func hasOMPAskPrompt(_ content: String) -> Bool {
  let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
  return lines.contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.contains("Enter select") && trimmed.contains("Esc cancel")
  }
}

nonisolated private func hasOMPWorkingLine(_ content: String) -> Bool {
  content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return isPiWorkingText(trimmed)
      || hasOMPInterruptHint(trimmed)
      || hasLabeledBrailleSpinner(trimmed)
  }
}

nonisolated private let piWorkingMessages: Set<String> = ["Working...", "Working…", "Interrupting…"]

nonisolated private func isPiWorkingText(_ line: String) -> Bool {
  if piWorkingMessages.contains(line) {
    return true
  }

  guard let spinner = line.unicodeScalars.first,
    (0x2800...0x28FF).contains(Int(spinner.value))
  else {
    return false
  }
  let message = String(line.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
  return piWorkingMessages.contains(message)
}

nonisolated private func isPiFramedWorkingFooter(_ line: String) -> Bool {
  guard line.hasPrefix("── "), line.hasSuffix("──") else { return false }
  let content = line.trimmingCharacters(in: CharacterSet(charactersIn: "─ "))
  return labeledBrailleSpinnerContent(content) == "Working"
}

nonisolated private func hasOMPInterruptHint(_ line: String) -> Bool {
  let interruptHints = ["⟦esc⟧", "⟨esc⟩", "[esc]"]
  return interruptHints.contains { hint in
    guard line.hasSuffix(hint) else { return false }
    return !line.dropLast(hint.count).trimmingCharacters(in: .whitespaces).isEmpty
  }
}

nonisolated private func hasLabeledBrailleSpinner(_ line: String) -> Bool {
  labeledBrailleSpinnerContent(line) != nil
}

nonisolated private func labeledBrailleSpinnerContent(_ line: String) -> String? {
  guard let first = line.unicodeScalars.first,
    (0x2800...0x28FF).contains(Int(first.value))
  else {
    return nil
  }

  let rest = String(line.unicodeScalars.dropFirst())
  guard rest.hasPrefix(" ") else { return nil }
  let content = rest.dropFirst().trimmingCharacters(in: .whitespaces)
  return content.contains(where: \.isLetter) ? content : nil
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

nonisolated func isNumberedChoice(_ option: String) -> Bool {
  guard let firstToken = option.split(whereSeparator: { $0.isWhitespace }).first,
    firstToken.last == "."
  else {
    return false
  }
  let number = firstToken.dropLast()
  return !number.isEmpty && number.allSatisfy(\.isNumber)
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

nonisolated func hasConfirmationPrompt(_ lower: String) -> Bool {
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

private nonisolated let agentSpinnerScalars: Set<UnicodeScalar> = [
  "·", "✱", "✲", "✳", "✴", "✵", "✶", "✷", "✸", "✹", "✺", "✻", "✼", "✽", "✾", "✿",
  "❀", "❁", "❂", "❃", "❇", "❈", "❉", "❊", "❋", "✢", "✣", "✤", "✥", "✦", "✧", "✨",
  "⊛", "⊕", "⊙", "◉", "◎", "◍", "⁂", "⁕", "※", "⍟", "☼", "★", "☆",
]

nonisolated func isAgentSpinnerScalar(_ scalar: UnicodeScalar) -> Bool {
  agentSpinnerScalars.contains(scalar)
}

nonisolated func hasSpinnerActivity(_ content: String) -> Bool {
  content.split(separator: "\n").contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.unicodeScalars.first else { return false }
    let rest = String(trimmed.unicodeScalars.dropFirst())
    return isAgentSpinnerScalar(first)
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

nonisolated private func detectQwen(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  if lower.contains("waiting for user confirmation")
    || lower.contains("do you want to proceed?")
    || hasConfirmationPrompt(lower)
  {
    return .blocked
  }
  if lower.contains("esc to cancel")
    || lower.contains("ctrl+c to cancel")
    || hasBrailleSpinner(content)
  {
    return .working
  }
  return .idle
}

// Qoder CLI (verified 1.0.48, live session): blocked dialogs are ephemeral
// overlays that vanish once answered, so full-window matching is safe.
// Permission menus always pair "Allow once" with "Reject and type something"
// (the second row varies by tool: "Allow for this session" for edits,
// "Always allow \"<cmd>\" for future sessions" for exec/MCP). Ask-user
// questions render an "Asking User" header with a fixed "Type Something"
// row; the plan-ready dialog pairs "Yes, start executing" with "Reject
// plan". An active turn shows a braille spinner footer ending in
// "(esc to cancel, <elapsed>)". Multi-token matches only — single labels
// like "Allow once" or "No" can appear in transcript text.
nonisolated private func detectQoder(_ content: String) -> AgentRawState {
  let lower = content.lowercased()
  if hasQoderPermissionMenu(lower) || hasQoderQuestionPrompt(lower) || hasQoderPlanReadyPrompt(lower) {
    return .blocked
  }
  if hasQoderWorkingFooter(content) {
    return .working
  }
  return .idle
}

nonisolated private func hasQoderPermissionMenu(_ lower: String) -> Bool {
  lower.contains("allow once") && lower.contains("reject and type something")
}

nonisolated private func hasQoderQuestionPrompt(_ lower: String) -> Bool {
  lower.contains("asking user") && lower.contains("type something")
}

nonisolated private func hasQoderPlanReadyPrompt(_ lower: String) -> Bool {
  lower.contains("yes, start executing") && lower.contains("reject plan")
}

nonisolated private func hasQoderWorkingFooter(_ content: String) -> Bool {
  content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.unicodeScalars.first else { return false }
    return (0x2800...0x28FF).contains(Int(first.value))
      && trimmed.lowercased().contains("(esc to cancel,")
  }
}

// Grok Build (verified 0.2.101): cancel mid-turn is Ctrl+C (Esc is a no-op).
// Approval dialogs pair numbered yes-rows ("Yes, proceed", "Yes, allow all
// edits during this session") with a reject row ("No, reject (type to add
// feedback)") above a "Ctrl+o:always-approve" footer; ask-user dialogs render
// "Waiting on answers for …" with a "Type your answer here" row. Working
// turns show a braille spinner line ("⠧ Thinking… 0.2s"). Multi-token matches
// only — single words like "approve" or "loading" appear in transcript text.
nonisolated private func detectGrok(_ content: String) -> AgentRawState {
  if hasGrokPermissionPrompt(content) || hasGrokQuestionPrompt(content) {
    return .blocked
  }
  if hasGrokWorkingSignal(content) {
    return .working
  }
  return .idle
}

nonisolated private func hasGrokPermissionPrompt(_ content: String) -> Bool {
  let lower = content.lowercased()
  // Tool approval dialog (verified on-screen, 0.2.101): a yes-row and a
  // reject-row are always rendered together. Requiring the pair keeps
  // transcript prose containing one of the phrases from matching.
  let hasApprovalYesRow =
    lower.contains("yes, proceed")
    || lower.contains("yes, allow")
    || lower.contains("yes, always allow")
    || lower.contains("(always-approve mode)")
  let hasApprovalNoRow =
    lower.contains("no, reject")
    || lower.contains("no, and tell grok")
  if hasApprovalYesRow && hasApprovalNoRow {
    return true
  }
  // Footer rendered only while an approval dialog is pending.
  if lower.contains("ctrl+o:always-approve") {
    return true
  }
  let hasAllowOnce = lower.contains("allow once")
  let hasAlwaysAllow =
    lower.contains("always allow this command")
    || lower.contains("always allow on all sessions")
    || lower.contains("always allow this exact command")
  let hasReject = lower.contains("reject")
  if hasAllowOnce && (hasAlwaysAllow || hasReject) {
    return true
  }
  if hasAlwaysAllow && hasReject {
    return true
  }
  if lower.contains("yes, and always allow this exact command")
    || lower.contains("yes, allow all edits")
  {
    return true
  }
  return false
}

nonisolated private func hasGrokQuestionPrompt(_ content: String) -> Bool {
  let lower = content.lowercased()
  // Ask-user dialog (verified on-screen, 0.2.101): "◆ Waiting on answers for
  // <question>" header plus a free-form "z (○) Type your answer here" row.
  return lower.contains("waiting on answers for")
    || lower.contains("type your answer here")
    || lower.contains("pending: question")
    || lower.contains("pending: other (type your own answer")
    || (lower.contains("awaiting your input")
      && (lower.contains("?") || lower.contains("select") || lower.contains("enter")))
}

nonisolated private func hasGrokWorkingSignal(_ content: String) -> Bool {
  let lower = content.lowercased()
  if lower.contains("tool calls in flight")
    || lower.contains("working tools")
    || lower.contains("still running:")
  {
    return true
  }
  // Status flag rendered while a turn is in progress (distinct from the
  // idle "Awaiting input" / "Awaiting your input" flags).
  if content.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed == "Loading" || trimmed.hasPrefix("Loading…") || trimmed.hasPrefix("Loading...")
  }) {
    return true
  }
  if hasBrailleSpinner(content) || hasSpinnerActivity(content) {
    return true
  }
  return false
}

nonisolated private func hasBrailleSpinner(_ content: String) -> Bool {
  content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.unicodeScalars.first else { return false }
    return (0x2800...0x28FF).contains(Int(first.value))
      && trimmed.contains(where: \.isLetter)
  }
}
