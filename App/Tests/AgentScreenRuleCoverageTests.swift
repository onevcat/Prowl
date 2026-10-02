import Testing

@testable import supacode

/// Every typed rule must be witnessed by a captured screen.
///
/// `ClaudeScreenProfileTests` and `CodexScreenProfileTests` already assert that
/// each rule ID is unique and runtime-prefixed, and inline synthetic screens
/// exercise the predicates. Synthetic screens are written from the same mental
/// model as the predicate they test, so they cannot falsify that model — only a
/// capture can. This test makes the corpus an obligation rather than a sample:
/// a rule with no captured witness is a rule whose shape has never been checked
/// against a real agent.
///
/// Quarantined fixtures do not count. They document a state the detector gets
/// wrong, so the rule they currently fire is the wrong one.
struct AgentScreenRuleCoverageTests {
  /// Rules that no captured screen reaches yet. Shrink this list by capturing the
  /// missing screen; never grow it to make a red test green.
  ///
  /// - `codex.confirmationChoices`: not merely uncaptured — possibly unreachable.
  ///   The captured command-permission screen satisfies this rule's structure
  ///   (numbered selection, "Would you like…", Yes and No options) but ends with
  ///   "Press enter to confirm or esc to cancel", so `codex.confirmationFooter`
  ///   matches first and this rule never runs. Deleting that one footer line from
  ///   the fixture flips the reason to `codex.confirmationChoices`, which is how
  ///   the shadowing was confirmed. Reaching it needs a Codex confirmation whose
  ///   last three lines after the selection carry none of the five footer markers,
  ///   and no such screen has been seen on 0.146.1. If none exists, the rule is
  ///   dead and should be removed rather than witnessed.
  private static let knownUnwitnessed: Set<String> = [
    "codex.confirmationChoices"
  ]

  @Test func everyTypedRuleHasACapturedWitness() throws {
    let witnessed = Set(
      try AgentScreenFixtureCorpus.load()
        .filter { !$0.isQuarantined }
        .map { $0.agent.detectScreen(in: $0.text).reason.identifier }
    )

    let typedRules =
      ClaudeScreenProfile.RuleID.all.map(\.rawValue)
      + CodexScreenProfile.RuleID.all.map(\.rawValue)

    let unwitnessed = Set(typedRules.filter { !witnessed.contains($0) })

    let regressed = unwitnessed.subtracting(Self.knownUnwitnessed).sorted()
    #expect(
      regressed.isEmpty,
      """
      Typed rules that lost their captured witness: \(regressed).
      Capture a screen that fires each one with `prowl read --source detection`,
      or quarantine it under known-misdetection if the detector gets it wrong.
      """
    )

    let stale = Self.knownUnwitnessed.subtracting(unwitnessed).sorted()
    #expect(stale.isEmpty, "These rules are witnessed now; drop them from knownUnwitnessed: \(stale)")
  }
}
