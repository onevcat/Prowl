import Foundation
import ProwlCLIShared

/// Empties an agent's input box the agent's own way before a delivery replaces its draft
/// (docs-ai 090). This presses the adapter's clear plan under `AgentKeySequenceGuard`, re-reads
/// the box after every key, and stops as soon as it reads empty; the box is never typed into
/// unless that re-read confirms it. Like `AgentPromptDelivery`, it observes the screen through
/// closures so the sequencing is testable with a `TestClock`.
///
/// Local activity is detected two ways. The editing stamp moves only for typed text and
/// deletions (`TerminalEditingActivity`), never for Prowl's own control keys, so any change to
/// it is someone typing on the Mac. The input generation counts every key, Prowl's own included:
/// it is recorded right after each own key, before any suspension, and any later change is
/// someone else's key (history, control keys) that may have replaced the box.
@MainActor
struct AgentComposerClearing {
  struct Observation: Equatable {
    /// Nil when the screen cannot be read.
    let reading: AgentComposerReading?
    let hasMarkedText: Bool
    let editingRevision: TimeInterval?
    /// The surface's input count (`GhosttySurfaceView.inputGeneration`).
    var inputGeneration: UInt64?
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
    let guardrail = AgentKeySequenceGuard(
      hasMarkedText: start.hasMarkedText, lastEditingAt: start.editingRevision, now: now())
    if let refusal = guardrail.refusal { return .refused(AgentInputRefusal(refusal, details: .init(reason: .editing))) }
    var pressed = 0
    var current = start
    var ownGeneration = start.inputGeneration
    while current.reading != .empty, pressed < presses {
      if let refusal = localActivity(in: current, guardrail: guardrail, ownGeneration: ownGeneration) {
        return .refused(partial(refusal, pressed: pressed))
      }
      guard !Task.isCancelled, press(key) else {
        return .refused(partial(AgentInputRefusal("The Mac did not accept the key."), pressed: pressed))
      }
      pressed += 1
      // Prowl's own key is the only input since the check above: record it before anything can
      // suspend, so every later observation is compared against it instead of adopted.
      guard let afterPress = observe() else { return .refused(gone) }
      ownGeneration = afterPress.inputGeneration
      let before = current.reading
      current = afterPress
      // Give the key time to reach the agent and the screen time to show the result: poll until
      // the box reads differently, or the budget for this key runs out.
      var polls = 0
      while current.reading == before, polls < Self.settlePolls {
        polls += 1
        do {
          try await clock.sleep(for: Self.settleInterval)
        } catch {
          return .refused(partial(cancelled, pressed: pressed))
        }
        guard let next = observe() else { return .refused(gone) }
        current = next
        if let refusal = localActivity(in: current, guardrail: guardrail, ownGeneration: ownGeneration) {
          return .refused(partial(refusal, pressed: pressed))
        }
      }
    }
    if let refusal = localActivity(in: current, guardrail: guardrail, ownGeneration: ownGeneration) {
      return .refused(partial(refusal, pressed: pressed))
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

  /// Someone typed on the Mac (the editing stamp or an input method), or some key other than
  /// Prowl's own reached the pane since the last own key.
  private func localActivity(
    in observation: Observation, guardrail: AgentKeySequenceGuard, ownGeneration: UInt64?
  ) -> AgentInputRefusal? {
    if let refusal = guardrail.checkRefusal(
      hasMarkedText: observation.hasMarkedText, lastEditingAt: observation.editingRevision)
    {
      return refusal
    }
    guard observation.inputGeneration == ownGeneration else {
      return AgentInputRefusal(
        String(localized: "Someone pressed a key in this pane on the Mac."), details: .init(reason: .editing))
    }
    return nil
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
