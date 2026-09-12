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
    let lines = snapshot.lines.map { $0.trimmingCharacters(in: .whitespaces) }
    guard let prompt = lines.lastIndex(where: isCodexPromptLine) else { return false }
    let suffix = lines.dropFirst(prompt + 1).filter { !$0.isEmpty }
    guard suffix.count == 1, let footer = suffix.first,
      footer.contains(" · "),
      footer.contains("Context ") || footer.contains("context left") || footer.contains("~/")
        || footer.contains("/"),
      !footer.contains("esc to interrupt"), !footer.contains("[Image #")
    else { return false }
    let contents = String(lines[prompt].dropFirst()).trimmingCharacters(in: .whitespaces)
    // Codex renders these hints in an empty composer; wrapped drafts are rejected above.
    return contents.isEmpty
      || [
        "Ask Codex to do anything", "Run /review on my current changes",
        "Find and fix a bug in @filename", "Explain this codebase",
        "Implement {feature}", "Improve documentation in @filename",
        "Write tests for @filename", "Summarize recent commits",
      ].contains(contents)
  }

  /// The formatter's dim SGR attribute distinguishes hints from identically worded drafts.
  /// This is read only at the public delivery boundary, not a second readiness state machine.
  nonisolated static func composerHasNoDraft(styledSnapshot: String) -> Bool {
    guard styledSnapshot.utf8.count <= 4 * 1024 * 1024 else { return false }
    let scalars = Array(styledSnapshot.unicodeScalars)
    var index = 0
    var dim = false
    var lines: [(String, [Bool])] = [("", [])]
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar.value == 27 {
        index += 1
        guard index < scalars.count else { return false }
        if scalars[index] == "]" {
          // Formatter snapshots prepend OSC palette/default colors; they contain no cells.
          index += 1
          while index < scalars.count, scalars[index].value != 7,
            !(scalars[index].value == 27 && index + 1 < scalars.count && scalars[index + 1] == "\\")
          {
            index += 1
          }
          guard index < scalars.count else { return false }
          index += scalars[index].value == 7 ? 1 : 2
          continue
        }
        guard scalars[index] == "[" else { return false }
        index += 1
        var parameters = ""
        while index < scalars.count, !(64...126).contains(scalars[index].value) {
          parameters.unicodeScalars.append(scalars[index])
          index += 1
        }
        guard index < scalars.count else { return false }
        if scalars[index] == "m" {
          updateDimAttribute(parameters: parameters, dim: &dim)
        }
      } else if scalar.value == 10 {
        lines.append(("", []))
      } else if scalar.value != 13 {
        lines[lines.count - 1].0.unicodeScalars.append(scalar)
        lines[lines.count - 1].1.append(dim)
      }
      index += 1
    }
    let plain = lines.map { $0.0 }.joined(separator: "\n")
    guard composerIsEmpty(in: .init(text: plain)),
      let line = lines.last(where: { isCodexPromptLine($0.0) }),
      let prompt = line.0.unicodeScalars.firstIndex(of: "›")
    else { return false }
    let offset =
      line.0.unicodeScalars.distance(from: line.0.unicodeScalars.startIndex, to: prompt) + 1
    return zip(line.0.unicodeScalars, line.1).dropFirst(offset).allSatisfy {
      CharacterSet.whitespaces.contains($0.0) || $0.1
    }
  }

  nonisolated private static func updateDimAttribute(parameters: String, dim: inout Bool) {
    let codes =
      parameters.isEmpty ? [0] : parameters.split(separator: ";").compactMap { Int($0) }
    var codeIndex = 0
    while codeIndex < codes.count {
      let code = codes[codeIndex]
      if code == 0 || code == 22 { dim = false }
      if code == 2 { dim = true }
      // Color components can equal 0/2/22 but are not standalone SGR attributes.
      if [38, 48, 58].contains(code), codeIndex + 1 < codes.count {
        codeIndex += codes[codeIndex + 1] == 2 ? 4 : 2
      }
      codeIndex += 1
    }
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
    // Background-terminal waits add a `└ command` detail row below the live
    // footer, before the composer and status line. The composer's starfield
    // fills otherwise blank rows with braille; those rows must not consume
    // the live-footer window. Keep every row that contains actual text.
    let contentLines = snapshot.lines.filter { line in
      !line.unicodeScalars.allSatisfy { scalar in
        CharacterSet.whitespaces.contains(scalar) || (0x2800...0x28FF).contains(scalar.value)
      }
    }
    self.workingFooter = contentLines.suffix(4).joined(separator: "\n")
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
