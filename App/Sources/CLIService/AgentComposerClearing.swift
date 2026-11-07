import Foundation
import ProwlCLIShared

/// Empties an agent's input box the agent's own way before a delivery replaces its draft
/// (docs-ai 090). This presses the adapter's clear plan under `AgentKeySequenceGuard`, re-reads
/// the box after every key, and stops as soon as it reads empty; the box is never typed into
/// unless that re-read confirms it. Like `AgentPromptDelivery`, it observes the screen through
/// closures so the sequencing is testable with a `TestClock`.
@MainActor
struct AgentComposerClearing {
  struct Observation: Equatable {
    /// Nil when the screen cannot be read.
    let reading: AgentComposerReading?
    let hasMarkedText: Bool
    let editingRevision: TimeInterval?
  }

  enum Outcome: Equatable {
    case cleared(AgentReplacedDraftPayload)
    case refused(AgentInputRefusal)
  }

  /// Presses of a line-kill key for a draft of `lines` rows: each row costs one press for its
  /// text and one for its newline, plus a margin for a trailing empty row.
  static func maximumPresses(forLines lines: Int) -> Int { min(2 * max(lines, 1) + 2, 64) }
  /// How long a key gets to change the screen before the next one.
  static let settlePolls = 10
  static let settleInterval = Duration.milliseconds(100)

  let observe: @MainActor () -> Observation?
  let press: @MainActor (String) -> Bool
  var clock: any Clock<Duration> = ContinuousClock()
  let plan: AgentComposerClearPlan
  let agentName: String
  let now: @MainActor () -> TimeInterval

  init(
    observe: @escaping @MainActor () -> Observation?, press: @escaping @MainActor (String) -> Bool,
    plan: AgentComposerClearPlan, agentName: String, clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.observe = observe
    self.press = press
    self.plan = plan
    self.agentName = agentName
    self.clock = clock
    self.now = now
  }

  func clear(_ draft: AgentComposerDraft) async -> Outcome {
    let key: String
    let presses: Int
    switch plan {
    case .unsupported:
      return .refused(.draft(draft, agentName: agentName, plan: plan))
    case .stash(let stashKey):
      key = stashKey
      presses = 1
    case .killLines(let killKey):
      key = killKey
      presses = Self.maximumPresses(forLines: draft.text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }
    guard let start = observe() else { return .refused(gone) }
    var guardrail = AgentKeySequenceGuard(
      hasMarkedText: start.hasMarkedText, lastEditingAt: start.editingRevision, now: now())
    if let refusal = guardrail.refusal { return .refused(AgentInputRefusal(refusal, details: .init(reason: .editing))) }
    var pressed = 0
    var current = start
    while current.reading != .empty, pressed < presses {
      if let refusal = guardrail.checkRefusal(
        hasMarkedText: current.hasMarkedText, lastEditingAt: current.editingRevision)
      {
        return .refused(partial(refusal, pressed: pressed))
      }
      guard !Task.isCancelled, press(key) else {
        return .refused(partial(AgentInputRefusal("The Mac did not accept the key."), pressed: pressed))
      }
      pressed += 1
      guard let afterPress = observe() else { return .refused(gone) }
      guardrail.noteSent(lastEditingAt: afterPress.editingRevision)
      current = afterPress
      // Give the key time to reach the agent and the screen time to show the result.
      for _ in 0..<Self.settlePolls where current.reading == afterPress.reading {
        do {
          try await clock.sleep(for: Self.settleInterval)
        } catch {
          return .refused(partial(cancelled, pressed: pressed))
        }
        guard let settled = observe() else { return .refused(gone) }
        current = settled
      }
    }
    guard current.reading == .empty else {
      return .refused(
        AgentInputRefusal(
          "\(agentName) still shows a draft after \(pressed) \(pressed == 1 ? "key" : "keys"). "
            + "Check the pane on the Mac before retrying.",
          details: .init(reason: .clearing, draft: draft.payload, replaceable: false, recovery: plan.recovery)))
    }
    return .cleared(.init(text: draft.text, isComplete: draft.isComplete, recovery: plan.recovery))
  }

  private var gone: AgentInputRefusal { AgentInputRefusal("The target terminal is no longer available.") }
  private var cancelled: AgentInputRefusal { AgentInputRefusal("The delivery was cancelled.") }

  /// A refusal after keys went in says so: the draft may be partly cleared on the Mac.
  private func partial(_ refusal: AgentInputRefusal, pressed: Int) -> AgentInputRefusal {
    guard pressed > 0 else { return refusal }
    return AgentInputRefusal(
      refusal.message + " The draft may be partly cleared on the Mac; nothing was sent.",
      details: refusal.details ?? .init(reason: .clearing, replaceable: false, recovery: plan.recovery))
  }
}
