import Foundation

enum CodexScreenProfile {
  enum RuleID {
    nonisolated static let directoryTrust = AgentScreenRuleID("codex.directoryTrust")
    nonisolated static let hookReview = AgentScreenRuleID("codex.hookReview")
    nonisolated static let signIn = AgentScreenRuleID("codex.signIn")
    nonisolated static let confirmationFooter = AgentScreenRuleID("codex.confirmationFooter")
    nonisolated static let confirmationChoices = AgentScreenRuleID("codex.confirmationChoices")
    nonisolated static let workingFooter = AgentScreenRuleID("codex.workingFooter")
    nonisolated static let backgroundTerminalFooter = AgentScreenRuleID(
      "codex.backgroundTerminalFooter")

    nonisolated static let emptyComposer = AgentScreenRuleID("codex.emptyComposer")

    // Keep exhaustive so prefix and uniqueness tests cover every emitted ID.
    nonisolated static let all = [
      directoryTrust,
      hookReview,
      signIn,
      confirmationFooter,
      confirmationChoices,
      workingFooter,
      backgroundTerminalFooter,
      emptyComposer,
    ]
  }

  nonisolated static func detect(in snapshot: AgentScreenSnapshot) -> AgentScreenDetection {
    let regions = CodexScreenRegions(snapshot: snapshot)

    if hasDirectoryTrustPrompt(regions) {
      return AgentScreenDetection(state: .blocked, reason: .matched(RuleID.directoryTrust))
    }
    if hasHookReviewPrompt(regions) {
      return AgentScreenDetection(state: .blocked, reason: .matched(RuleID.hookReview))
    }
    if hasSignInPrompt(regions) {
      return AgentScreenDetection(state: .blocked, reason: .matched(RuleID.signIn))
    }
    if hasConfirmationFooter(regions) {
      return AgentScreenDetection(state: .blocked, reason: .matched(RuleID.confirmationFooter))
    }
    if hasConfirmationChoices(regions) {
      return AgentScreenDetection(state: .blocked, reason: .matched(RuleID.confirmationChoices))
    }
    if hasWorkingFooter(regions) {
      return AgentScreenDetection(state: .working, reason: .matched(RuleID.workingFooter))
    }
    if hasBackgroundTerminalFooter(regions) {
      return AgentScreenDetection(
        state: .working, reason: .matched(RuleID.backgroundTerminalFooter))
    }
    if composerIsEmpty(in: snapshot) {
      return AgentScreenDetection(state: .idle, reason: .matched(RuleID.emptyComposer))
    }
    return AgentScreenDetection(state: .idle, reason: .noRuleMatched)
  }

  /// Only the live bottom composer, followed by Codex's status line, is evidence.
  /// Historical prompts and arbitrary footer text must not authorize delivery.
  nonisolated static func composerIsEmpty(in snapshot: AgentScreenSnapshot) -> Bool {
    let lines = snapshot.lines.map {
      codexLineWithoutStarfield($0).trimmingCharacters(in: .whitespaces)
    }
    guard let prompt = liveComposerPromptIndex(in: lines) else { return false }
    let contents = String(lines[prompt].dropFirst()).trimmingCharacters(in: .whitespaces)
    // Codex renders these hints in an empty composer; wrapped drafts are rejected above.
    // A braille-only draft is indistinguishable from stars without styled evidence.
    let originalContents = snapshot.lines[prompt].trimmingCharacters(in: .whitespaces).dropFirst()
    return (contents.isEmpty && originalContents.allSatisfy(\.isWhitespace))
      || [
        "Ask Codex to do anything", "Run /review on my current changes",
        "Find and fix a bug in @filename", "Explain this codebase",
        "Implement {feature}", "Improve documentation in @filename",
        "Write tests for @filename", "Summarize recent commits",
      ].contains(contents)
  }

  /// The prompt row of the live composer: the last `›` row, followed only by the status line
  /// and the optional shortcut hint row. A wrapped draft or a menu puts other rows there.
  nonisolated private static func liveComposerPromptIndex(in lines: [String]) -> Int? {
    guard let prompt = lines.lastIndex(where: isCodexPromptLine) else { return nil }
    let suffix = lines.dropFirst(prompt + 1).filter { !$0.isEmpty }
    // Codex 0.158 adds a shortcut hint row below the status line.
    guard suffix.count == 1 || (suffix.count == 2 && isShortcutHintRow(suffix[1])),
      let footer = suffix.first, isStatusFooterRow(footer)
    else { return nil }
    return prompt
  }

  nonisolated private static func isShortcutHintRow(_ line: String) -> Bool {
    (line.contains(" for shortcuts") || line.contains(" for agents"))
      && !line.contains("esc to interrupt") && !line.contains("[Image #")
  }

  /// The live composer at the delivery boundary (docs-ai 090): the last `›` row and the rows up
  /// to the status footer. The prompt row showing only dim text after `›` is Codex's placeholder,
  /// whatever the words, which the formatter's dim SGR attribute tells from an identically worded
  /// draft; an image marker is never a hint. Rows between the prompt and the footer continue a
  /// draft: their text is kept as shown, past the box's two-column margin, with interior blank
  /// rows, but a soft wrap and a newline look the same, so only a one-row draft is complete. No
  /// footer, or an unreadable snapshot, is an unrecognized box.
  nonisolated static func composerReading(styledSnapshot: String) -> AgentComposerReading {
    guard let styled = StyledScreenSnapshot(styledSnapshot: styledSnapshot) else { return .unrecognized }
    let lines = styled.rows.map { codexLineWithoutStarfield($0.text).trimmingCharacters(in: .whitespaces) }
    guard let prompt = lines.lastIndex(where: isCodexPromptLine),
      let footer = lines.indices.dropFirst(prompt + 1).first(where: { isStatusFooterRow(lines[$0]) }),
      let marker = styled.rows[prompt].text.unicodeScalars.firstIndex(of: "›")
    else { return .unrecognized }
    let row = styled.rows[prompt]
    let offset = row.text.unicodeScalars.distance(from: row.text.unicodeScalars.startIndex, to: marker) + 1
    let first = composerRowText(row.text, after: marker, in: row.text.unicodeScalars)
    var continuation = styled.rows[(prompt + 1)..<footer].map { continuationRowText($0.text) }
    while continuation.last?.isEmpty == true { continuation.removeLast() }
    while continuation.first?.isEmpty == true { continuation.removeFirst() }
    let hasImage = row.text.contains("[Image #")
    if continuation.isEmpty, !hasImage, first.isEmpty || row.showsOnlyDimText(from: offset) { return .empty }
    let text = ([first] + continuation).joined(separator: "\n")
    let isComplete = continuation.isEmpty && !hasImage && !text.contains("[Pasted Content")
    return .draft(.init(text: text, isComplete: isComplete))
  }

  /// The prompt row's text after `›` and its one separating space, trailing blanks dropped.
  nonisolated private static func composerRowText(
    _ text: String, after marker: String.UnicodeScalarView.Index, in scalars: String.UnicodeScalarView
  ) -> String {
    var start = scalars.index(after: marker)
    if start < scalars.endIndex, scalars[start] == " " { start = scalars.index(after: start) }
    return trimmingTrailingWhitespace(String(scalars[start...]))
  }

  /// A continuation row past the two-column margin that aligns it under the prompt's text, with
  /// its own indentation kept.
  nonisolated private static func continuationRowText(_ text: String) -> String {
    let cleaned = codexLineWithoutStarfield(text)
    var start = cleaned.startIndex
    for _ in 0..<2 where start < cleaned.endIndex && cleaned[start] == " " {
      start = cleaned.index(after: start)
    }
    return trimmingTrailingWhitespace(String(cleaned[start...]))
  }

  nonisolated private static func trimmingTrailingWhitespace(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex, text[text.index(before: end)].isWhitespace {
      end = text.index(before: end)
    }
    return String(text[..<end])
  }

  /// `composerReading(styledSnapshot:)` reads empty. Read only at the public delivery boundary,
  /// not a second readiness state machine.
  nonisolated static func composerHasNoDraft(styledSnapshot: String) -> Bool {
    composerReading(styledSnapshot: styledSnapshot) == .empty
  }

  /// Codex's status line below the composer: model and context, or the working directory.
  nonisolated private static func isStatusFooterRow(_ line: String) -> Bool {
    line.contains(" · ")
      && (line.contains("Context ") || line.contains("context left") || line.contains("~/") || line.contains("/"))
      && !line.contains("esc to interrupt") && !line.contains("[Image #")
  }

  /// Raw current interaction text for an actionable blocked screen. This deliberately
  /// preserves TUI selection markers and keyboard hints instead of reconstructing options.
  nonisolated static func blockerText(in snapshot: AgentScreenSnapshot) -> String? {
    let regions = CodexScreenRegions(snapshot: snapshot)
    guard detect(in: snapshot).state == .blocked else { return nil }
    if let selectedChoice = regions.selectedChoice {
      return selectedChoice.interactionText
    }
    if hasSignInPrompt(regions) {
      return regions.signInInteractionText
    }
    return nil
  }

  nonisolated private static func hasDirectoryTrustPrompt(_ regions: CodexScreenRegions) -> Bool {
    hasSelectedChoice(
      regions,
      matchingAnyOf: ["1. yes, continue", "2. no, quit"],
      withBefore: ["do you trust the contents of this directory?"],
      andAround: ["1. yes, continue", "2. no, quit"],
      andAfter: ["press enter to continue"]
    )
      || hasSelectedChoice(
        regions,
        matchingAnyOf: ["1. trust and continue", "2. back to agent command center"],
        withBefore: ["trust this folder?"],
        andAround: ["1. trust and continue", "2. back to agent command center"],
        andAfter: ["enter continue · esc back"]
      )
  }

  nonisolated private static func hasHookReviewPrompt(_ regions: CodexScreenRegions) -> Bool {
    hasSelectedChoice(
      regions,
      matchingAnyOf: [
        "1. review hooks",
        "2. trust all and continue",
        "3. continue without trusting (hooks won't run)",
      ],
      withBefore: ["hooks need review"],
      andAround: ["1. review hooks", "2. trust all and continue", "3. continue without trusting"],
      andAfter: ["press enter to confirm or esc to go back"]
    )
  }

  nonisolated private static func hasSelectedChoice(
    _ regions: CodexScreenRegions,
    matchingAnyOf options: Set<String>,
    withBefore beforeNeedles: [String],
    andAround aroundNeedles: [String],
    andAfter afterNeedles: [String]
  ) -> Bool {
    guard let selection = regions.selectedChoice, options.contains(selection.choice) else {
      return false
    }
    return beforeNeedles.allSatisfy(selection.beforeLower.contains)
      && aroundNeedles.allSatisfy(selection.aroundLower.contains)
      && afterNeedles.allSatisfy(selection.afterLower.contains)
  }

  nonisolated private static func hasSignInPrompt(_ regions: CodexScreenRegions) -> Bool {
    guard
      let selected = regions.signInMenuLines.last(where: { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.first == "›" || trimmed.first == ">"
      })
    else {
      return false
    }
    let choice = selected.trimmingCharacters(in: .whitespaces)
      .dropFirst()
      .trimmingCharacters(in: .whitespaces)
      .lowercased()
    guard
      choice.hasPrefix("1. sign in with chatgpt")
        || choice.hasPrefix("2. sign in with device code")
        || choice.hasPrefix("3. provide your own api key")
    else {
      return false
    }
    let lower = regions.signInMenuLines.joined(separator: "\n").lowercased()
    return lower.contains("welcome to codex, openai's command-line coding agent")
      && lower.contains("2. sign in with device code")
      && lower.contains("3. provide your own api key")
      && lower.contains("press enter to continue")
  }

  nonisolated private static func hasConfirmationFooter(_ regions: CodexScreenRegions) -> Bool {
    guard let selection = regions.selectedChoice, isNumberedChoice(selection.choice) else {
      return false
    }
    return selection.footerLower.contains("press enter to confirm or esc to cancel")
      || selection.footerLower.contains("enter to submit answer")
      || selection.footerLower.contains("allow command?")
      || selection.footerLower.contains("[y/n]")
      || selection.footerLower.contains("yes (y)")
  }

  nonisolated private static func hasConfirmationChoices(_ regions: CodexScreenRegions) -> Bool {
    guard let selection = regions.selectedChoice, isNumberedChoice(selection.choice) else {
      return false
    }
    guard
      selection.interactionLower.contains("do you want")
        || selection.interactionLower.contains("would you like")
    else {
      return false
    }

    let hasYes = selection.options.contains { option in
      option == "yes" || option.hasPrefix("1. yes") || option.hasPrefix("2. yes")
    }
    let hasNo = selection.options.contains { option in
      option == "no" || option.hasPrefix("2. no") || option.hasPrefix("3. no")
    }
    return hasYes && hasNo
  }

  nonisolated private static func hasWorkingFooter(_ regions: CodexScreenRegions) -> Bool {
    hasInterruptibleFooter(regions, prefixes: [" Working ("])
  }

  nonisolated private static func hasBackgroundTerminalFooter(_ regions: CodexScreenRegions) -> Bool {
    hasInterruptibleFooter(
      regions,
      prefixes: [
        " Waiting for background terminal (",
        " Waiting for background terminals (",
      ]
    )
  }

  nonisolated private static func hasInterruptibleFooter(
    _ regions: CodexScreenRegions,
    prefixes: [String]
  ) -> Bool {
    regions.workingFooter.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.first == "•" || trimmed.first == "◦" else { return false }
      let body = trimmed.dropFirst()
      guard prefixes.contains(where: body.hasPrefix) else { return false }
      guard let hint = body.range(of: "esc to interrupt)") else { return false }
      let trailing = body[hint.upperBound...]
      return trailing.isEmpty || trailing.hasPrefix(" · ")
    }
  }
}

private struct CodexScreenRegions: Sendable {
  struct SelectedChoice: Sendable {
    let choice: String
    let beforeLower: String
    let aroundLower: String
    let afterLower: String
    let footerLower: String
    let interactionLower: String
    let interactionText: String
    let options: [String]
  }

  let selectedChoice: SelectedChoice?
  let signInMenuLines: [String]
  let signInInteractionText: String
  let workingFooter: String

  nonisolated init(snapshot: AgentScreenSnapshot) {
    self.selectedChoice = Self.makeSelectedChoice(from: snapshot.lines)
    let signInMenuLines = Array(snapshot.lines.suffix(18))
    self.signInMenuLines = signInMenuLines
    let signInStart =
      signInMenuLines.lastIndex { line in
        line.lowercased().contains("welcome to codex, openai's command-line coding agent")
      } ?? signInMenuLines.startIndex
    self.signInInteractionText = signInMenuLines[signInStart...]
      .joined(separator: "\n")
      .trimmingCharacters(in: .newlines)
    // The composer's starfield fills otherwise blank rows with braille; those
    // rows must not consume the live-footer window. Keep every row that
    // contains actual text.
    let contentLines = snapshot.lines.filter { line in
      !line.unicodeScalars.allSatisfy { scalar in
        CharacterSet.whitespaces.contains(scalar) || (0x2800...0x28FF).contains(scalar.value)
      }
    }
    // The live footer sits directly above the composer. Detail rows such as a
    // background `└ command` or a `└ Tip:` can sit between them, and Codex 0.158
    // adds a shortcut hint row below the status line, so the bottom window alone
    // can lose the footer. Also read the rows right above the composer.
    let composerIndex = contentLines.lastIndex { isCodexPromptLine(codexLineWithoutStarfield($0)) }
    let aboveComposer = composerIndex.map { contentLines[..<$0].suffix(3) } ?? []
    self.workingFooter = (aboveComposer + contentLines.suffix(4)).joined(separator: "\n")
  }

  nonisolated private static func makeSelectedChoice(from lines: [String]) -> SelectedChoice? {
    guard let promptIndex = lines.lastIndex(where: isCodexPromptLine) else {
      return nil
    }

    let lowerBound = max(lines.startIndex, promptIndex - 6)
    let interactionStart =
      lines[...promptIndex]
      .lastIndex(where: isCodexInteractionStart) ?? lowerBound
    let afterStart = lines.index(after: promptIndex)
    let afterEnd = min(lines.endIndex, afterStart + 6)
    let interactionLines = lines[interactionStart..<lines.endIndex]
    let footerText = lines[afterStart..<lines.endIndex].joined(separator: "\n")
    return SelectedChoice(
      choice: normalizedCodexChoice(lines[promptIndex]),
      beforeLower: lines[lowerBound..<promptIndex].joined(separator: "\n").lowercased(),
      aroundLower: lines[lowerBound..<afterEnd].joined(separator: "\n").lowercased(),
      afterLower: lines[afterStart..<afterEnd].joined(separator: "\n").lowercased(),
      footerLower: agentDetectionRecentLines(footerText, limit: 3).lowercased(),
      interactionLower: interactionLines.joined(separator: "\n").lowercased(),
      interactionText: interactionLines.joined(separator: "\n").trimmingCharacters(in: .newlines),
      options: interactionLines.map(normalizedCodexChoice)
    )
  }
}

nonisolated private func isCodexInteractionStart(_ line: String) -> Bool {
  let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
  return lower.hasPrefix("do you trust ")
    || lower.hasPrefix("do you want ")
    || lower.hasPrefix("would you like ")
    || lower == "hooks need review"
    || lower == "folder access"
}

/// Astra paints braille stars into blank composer cells. Replace each star with a
/// space so cell positions stay intact and separate words do not join.
nonisolated private func codexLineWithoutStarfield(_ line: String) -> String {
  String(
    String.UnicodeScalarView(
      line.unicodeScalars.map { scalar in
        (0x2800...0x28FF).contains(scalar.value) ? Unicode.Scalar(" ") : scalar
      })
  )
}

nonisolated private func isCodexPromptLine(_ line: String) -> Bool {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  guard trimmed.first == "›" else { return false }
  let remainder = trimmed.dropFirst()
  return remainder.isEmpty || remainder.first?.isWhitespace == true
}

nonisolated private func normalizedCodexChoice(_ line: String) -> String {
  let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
  let withoutSelection = trimmed.hasPrefix("›") ? trimmed.dropFirst() : trimmed[...]
  return withoutSelection.trimmingCharacters(in: .whitespaces)
}
