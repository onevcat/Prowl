import Foundation
import ProwlCLIShared

/// Why text cannot go into an agent's input box now: the message for the person, and the
/// governed `error.details.input` a mirror or a CLI caller can act on (docs-ai 090).
nonisolated struct AgentInputRefusal: Equatable, Sendable {
  let message: String
  let details: AgentInputRefusalDetails?

  init(_ message: String, details: AgentInputRefusalDetails? = nil) {
    self.message = message
    self.details = details
  }

  /// A draft someone left in the box, with the start of it so the person sees what is in the way.
  static func draft(_ draft: AgentComposerDraft, agentName: String, plan: AgentComposerClearPlan) -> AgentInputRefusal {
    let collapsed = AgentComposerEcho.collapsed(draft.text)
    let excerpt = collapsed.count > 40 ? collapsed.prefix(40) + "…" : collapsed[...]
    return AgentInputRefusal(
      "\(agentName) has an existing draft or attachment (“\(excerpt)”). Clear it on Host before dispatching.",
      details: .init(reason: .draft, draft: draft.payload, replaceable: plan.isSupported, recovery: plan.recovery))
  }
}

/// Result of delivering a line under a draft policy (`agents.input`, `agents dispatch`).
nonisolated enum AgentLineOutcome: Equatable, Sendable {
  case submitted(replacedDraft: AgentReplacedDraftPayload?)
  /// The input box refused the line, before or after clearing a draft.
  case refused(AgentInputRefusal)
  /// Nothing was typed.
  case notInserted
  /// The line may remain in the input box without Enter.
  case notSubmitted
}

nonisolated enum AgentDispatchInputProtection {
  static let recentEditingWindow: TimeInterval = 2

  static func refusal(hasMarkedText: Bool, lastEditingAt: TimeInterval?, now: TimeInterval) -> AgentInputRefusal? {
    if hasMarkedText {
      return AgentInputRefusal(
        "Host is composing text with an input method. Finish editing before dispatching.",
        details: .init(reason: .composing))
    }
    guard now.isFinite, lastEditingAt?.isFinite != false else {
      return AgentInputRefusal("Host input activity is unavailable.")
    }
    if let lastEditingAt, now - lastEditingAt < recentEditingWindow {
      return AgentInputRefusal(
        "Host was just edited locally. Wait before dispatching.", details: .init(reason: .editing))
    }
    return nil
  }
}

/// Local input protection across a sequence of keys Prowl presses in a pane (docs-ai 089 review
/// S4-R3). The first key needs the usual quiet period. After that, the operation's own keys may
/// move the editing stamp, so the guard records the stamp after each key it sends: any later
/// change, or marked text, means someone is editing on the Mac and the next key must not go.
nonisolated struct AgentKeySequenceGuard: Equatable, Sendable {
  let refusal: String?
  private var ownStamp: TimeInterval?

  init(hasMarkedText: Bool, lastEditingAt: TimeInterval?, now: TimeInterval) {
    refusal =
      AgentDispatchInputProtection.refusal(hasMarkedText: hasMarkedText, lastEditingAt: lastEditingAt, now: now)?
      .message
    ownStamp = lastEditingAt
  }

  mutating func noteSent(lastEditingAt: TimeInterval?) {
    ownStamp = lastEditingAt
  }

  func check(hasMarkedText: Bool, lastEditingAt: TimeInterval?) -> String? {
    checkRefusal(hasMarkedText: hasMarkedText, lastEditingAt: lastEditingAt)?.message
  }

  func checkRefusal(hasMarkedText: Bool, lastEditingAt: TimeInterval?) -> AgentInputRefusal? {
    if hasMarkedText {
      return AgentInputRefusal(
        String(localized: "Someone is typing with an input method on the Mac. Finish there first."),
        details: .init(reason: .composing))
    }
    if lastEditingAt != ownStamp {
      return AgentInputRefusal(
        String(localized: "Someone is typing in this pane on the Mac."), details: .init(reason: .editing))
    }
    return nil
  }
}
