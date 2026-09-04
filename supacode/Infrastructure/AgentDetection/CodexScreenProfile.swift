import Foundation

enum CodexScreenProfile {
  enum RuleID {
    nonisolated static let directoryTrust = AgentScreenRuleID("codex.directoryTrust")
    nonisolated static let hookReview = AgentScreenRuleID("codex.hookReview")
    nonisolated static let signIn = AgentScreenRuleID("codex.signIn")
    nonisolated static let confirmationFooter = AgentScreenRuleID("codex.confirmationFooter")
    nonisolated static let confirmationChoices = AgentScreenRuleID("codex.confirmationChoices")
    nonisolated static let workingFooter = AgentScreenRuleID("codex.workingFooter")

    // Keep exhaustive so prefix and uniqueness tests cover every emitted ID.
    nonisolated static let all = [
      directoryTrust,
      hookReview,
      signIn,
      confirmationFooter,
      confirmationChoices,
      workingFooter,
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
    return AgentScreenDetection(state: .idle, reason: .noRuleMatched)
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
    regions.workingFooter.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.first == "•" || trimmed.first == "◦" else { return false }
      let body = trimmed.dropFirst()
      let workingPrefixes = [
        " Working (",
        " Waiting for background terminal (",
        " Waiting for background terminals (",
      ]
      guard workingPrefixes.contains(where: body.hasPrefix) else { return false }
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
    self.workingFooter = agentDetectionRecentLines(snapshot.text, limit: 3)
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
