import Testing

@testable import supacode

struct CodexScreenProfileTests {
  @Test func ruleIDsAreUniqueAndRuntimePrefixed() {
    let ruleIDs = CodexScreenProfile.RuleID.all

    #expect(Set(ruleIDs).count == ruleIDs.count)
    #expect(ruleIDs.allSatisfy { $0.rawValue.hasPrefix("codex.") })
  }

  @Test func capturedFixturesHaveStableReasons() throws {
    let expectedReasons: [String: AgentScreenDetectionReason] = [
      "codex/0.146.1/blocked/command-permission.txt": .matched(
        CodexScreenProfile.RuleID.confirmationFooter
      ),
      "codex/0.146.1/blocked/directory-trust.txt": .matched(
        CodexScreenProfile.RuleID.directoryTrust
      ),
      "codex/0.146.1/blocked/hook-review.txt": .matched(CodexScreenProfile.RuleID.hookReview),
      "codex/0.146.1/blocked/sign-in-selection.txt": .matched(CodexScreenProfile.RuleID.signIn),
      "codex/0.146.1/idle/composer.txt": .noRuleMatched,
      "codex/0.146.1/idle/quoted-directory-trust.txt": .noRuleMatched,
      "codex/0.146.1/working/foreground-footer.txt": .matched(
        CodexScreenProfile.RuleID.workingFooter
      ),
      "codex/0.153.2/working/background-terminal-footer.txt": .matched(
        CodexScreenProfile.RuleID.backgroundTerminalFooter
      ),
    ]
    let fixtures = try AgentScreenFixtureCorpus.load().filter { $0.agent == .codex }

    #expect(fixtures.count == expectedReasons.count)
    for fixture in fixtures {
      let detection = DetectedAgent.codex.detectScreen(in: fixture.text)
      #expect(detection.state == fixture.currentState)
      #expect(detection.reason == expectedReasons[fixture.relativePath])
    }
  }

  @Test func structuredChoicesExplainBlockedWithoutAFooter() {
    let detection = CodexScreenProfile.detect(
      in: AgentScreenSnapshot(
        text: """
            Would you like to run the following command?
          › 1. Yes, proceed
            2. No, cancel
          """
      )
    )

    #expect(detection.state == .blocked)
    #expect(detection.reason == .matched(CodexScreenProfile.RuleID.confirmationChoices))
  }

  @Test func blockerTextCropsEveryCapturedBlockedFixture() throws {
    let fixtures = try AgentScreenFixtureCorpus.load().filter {
      $0.agent == .codex && $0.expectedState == .blocked
    }

    for fixture in fixtures {
      let blocker = CodexScreenProfile.blockerText(
        in: DetectedAgent.codex.detectionSnapshot(from: fixture.text)
      )

      #expect(blocker != nil)
      #expect(blocker?.contains("OpenAI Codex (v") == false)
      #expect(blocker?.contains("<USAGE_STATUS>") == false)
    }
  }

  @Test func blockerTextRejectsQuotedHistoricalPrompt() throws {
    let fixture = try #require(
      AgentScreenFixtureCorpus.load().first {
        $0.relativePath == "codex/0.146.1/idle/quoted-directory-trust.txt"
      }
    )

    let blocker = CodexScreenProfile.blockerText(
      in: DetectedAgent.codex.detectionSnapshot(from: fixture.text)
    )

    #expect(blocker == nil)
  }

  @Test func blockerTextKeepsQuestionAboveLongWrappedInteraction() {
    let filler = (1...14).map { "  wrapped command detail \($0)" }.joined(separator: "\n")
    let snapshot = DetectedAgent.codex.detectionSnapshot(
      from: """
        Historical output that must not be returned.

          Would you like to run the following command?
        \(filler)
        › 1. Yes, proceed (y)
          2. No, cancel (esc)

          Press enter to confirm or esc to cancel
        """
    )

    let blocker = CodexScreenProfile.blockerText(in: snapshot)

    #expect(blocker?.contains("Would you like to run the following command?") == true)
    #expect(blocker?.contains("wrapped command detail 14") == true)
    #expect(blocker?.contains("Historical output") == false)
  }

  @Test func blockerTextPreservesCodexQuestionChoicesAndKeyboardHints() throws {
    let fixture = try AgentScreenFixtureCorpus.load()
      .first { $0.relativePath == "codex/0.146.1/blocked/command-permission.txt" }
    let text = try #require(fixture).text

    let blocker = CodexScreenProfile.blockerText(in: DetectedAgent.codex.detectionSnapshot(from: text))

    #expect(blocker?.contains("Would you like to run the following command?") == true)
    #expect(blocker?.contains("Environment: local") == true)
    #expect(blocker?.contains("$ touch permission-probe.txt") == true)
    #expect(blocker?.contains("› 1. Yes, proceed (y)") == true)
    #expect(blocker?.contains("3. No, and tell Codex what to do differently (esc)") == true)
    #expect(blocker?.contains("Press enter to confirm or esc to cancel") == true)
    #expect(blocker?.contains("OpenAI Codex") == false)
    #expect(blocker?.contains("Run touch permission-probe.txt using the shell now.") == false)
  }
}
