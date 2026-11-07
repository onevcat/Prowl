import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

/// The clearing executor presses the adapter's plan under the key guard and only reports the
/// box cleared when it re-reads as empty (docs-ai 090).
@MainActor
struct AgentComposerClearingTests {
  private final class Screen {
    var reading: AgentComposerReading?
    var hasMarkedText = false
    var editingRevision: TimeInterval? = 1
    var pressed: [String] = []
    var accepts = true
    /// What each press leaves in the box, in order; the last entry repeats.
    var responses: [AgentComposerReading?] = []

    init(_ reading: AgentComposerReading) { self.reading = reading }

    func observation() -> AgentComposerClearing.Observation {
      .init(reading: reading, hasMarkedText: hasMarkedText, editingRevision: editingRevision)
    }

    func press(_ key: String) -> Bool {
      pressed.append(key)
      guard accepts else { return false }
      // The agent's own handling of the key moves the local editing stamp like typing does.
      editingRevision = (editingRevision ?? 0) + 1
      if !responses.isEmpty { reading = responses.removeFirst() }
      return true
    }
  }

  private func clearing(
    _ screen: Screen, plan: AgentComposerClearPlan, clock: TestClock<Duration>,
    observeNil: Bool = false
  ) -> AgentComposerClearing {
    AgentComposerClearing(
      observe: { observeNil ? nil : screen.observation() }, press: { screen.press($0) },
      plan: plan, agentName: "Claude", clock: clock, now: { 100 })
  }

  @Test func stashPressesOnceAndReportsTheRecovery() async {
    let clock = TestClock()
    let screen = Screen(.draft(.init(text: "hello", isComplete: true)))
    screen.responses = [.empty]
    let task = Task {
      await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock).clear(
        .init(text: "hello", isComplete: true))
    }
    await clock.advance(by: .milliseconds(100))
    #expect(await task.value == .cleared(.init(text: "hello", isComplete: true, recovery: .stash)))
    #expect(screen.pressed == ["ctrl-s"])
  }

  @Test func aKeyThatDoesNotEmptyTheBoxIsAPartialClearRefusal() async {
    let clock = TestClock()
    let screen = Screen(.draft(.init(text: "hello", isComplete: true)))
    let task = Task {
      await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock).clear(
        .init(text: "hello", isComplete: true))
    }
    await clock.advance(by: .seconds(2))
    let outcome = await task.value
    guard case .refused(let refusal) = outcome else {
      Issue.record("expected a refusal, got \(outcome)")
      return
    }
    #expect(refusal.details?.reason == .clearing)
    #expect(refusal.details?.replaceable == false)
    #expect(refusal.details?.draft?.text == "hello")
    #expect(screen.pressed == ["ctrl-s"])
  }

  @Test func killLinesStopsAtTheFirstEmptyReadingAndCapsPresses() async {
    let clock = TestClock()
    let draft = AgentComposerDraft(text: "l1\nl2\nl3", isComplete: true)
    let screen = Screen(.draft(draft))
    // Codex removes a line's text with one press and its newline with the next.
    screen.responses = [
      .draft(.init(text: "l1\nl2\n", isComplete: true)),
      .draft(.init(text: "l1\nl2", isComplete: true)),
      .draft(.init(text: "l1\n", isComplete: true)), .draft(.init(text: "l1", isComplete: true)),
      .empty,
    ]
    let task = Task {
      await clearing(screen, plan: .killLines(key: "ctrl-u"), clock: clock).clear(draft)
    }
    await clock.advance(by: .seconds(2))
    #expect(
      await task.value == .cleared(.init(text: "l1\nl2\nl3", isComplete: true, recovery: nil)))
    #expect(screen.pressed.count == 5)

    let stubborn = Screen(.draft(draft))
    let capped = Task {
      await clearing(stubborn, plan: .killLines(key: "ctrl-u"), clock: clock).clear(draft)
    }
    await clock.advance(by: .seconds(20))
    guard case .refused(let refusal) = await capped.value else {
      Issue.record("expected a refusal")
      return
    }
    #expect(refusal.details?.reason == .clearing)
    #expect(stubborn.pressed.count == AgentComposerClearing.maximumPresses(forLines: 3))
    #expect(AgentComposerClearing.maximumPresses(forLines: 1) == 4)
    #expect(AgentComposerClearing.maximumPresses(forLines: 100) == 64)
  }

  @Test func someoneTypingOnTheMacStopsTheSequence() async {
    let clock = TestClock()
    let draft = AgentComposerDraft(text: "l1\nl2", isComplete: true)
    let screen = Screen(.draft(draft))
    screen.responses = [.draft(.init(text: "l1\n", isComplete: true))]
    let task = Task {
      await clearing(screen, plan: .killLines(key: "ctrl-u"), clock: clock).clear(draft)
    }
    await clock.advance(by: .milliseconds(100))
    // A local keystroke after Prowl's first key moves the stamp again.
    screen.editingRevision = 50
    await clock.advance(by: .seconds(2))
    guard case .refused(let refusal) = await task.value else {
      Issue.record("expected a refusal")
      return
    }
    #expect(refusal.details?.reason == .editing)
    #expect(refusal.message.contains("partly cleared"))
    #expect(screen.pressed == ["ctrl-u"])

    let composing = Screen(.draft(draft))
    composing.hasMarkedText = true
    let refusedAtOnce = await clearing(composing, plan: .killLines(key: "ctrl-u"), clock: clock)
      .clear(draft)
    guard case .refused(let first) = refusedAtOnce else {
      Issue.record("expected a refusal")
      return
    }
    #expect(first.details?.reason == .editing)
    #expect(composing.pressed.isEmpty)
  }

  @Test func unsupportedPlanRefusesWithoutPressingAndAGoneScreenRefuses() async {
    let clock = TestClock()
    let draft = AgentComposerDraft(text: "hello", isComplete: true)
    let screen = Screen(.draft(draft))
    let refused = await clearing(screen, plan: .unsupported, clock: clock).clear(draft)
    guard case .refused(let refusal) = refused else {
      Issue.record("expected a refusal")
      return
    }
    #expect(refusal.details?.reason == .draft)
    #expect(refusal.details?.replaceable == false)
    #expect(screen.pressed.isEmpty)

    let gone = await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock, observeNil: true)
      .clear(draft)
    guard case .refused(let goneRefusal) = gone else {
      Issue.record("expected a refusal")
      return
    }
    #expect(goneRefusal.message.contains("no longer available"))

    screen.accepts = false
    guard
      case .refused(let notAccepted) = await clearing(
        screen, plan: .stash(key: "ctrl-s"), clock: clock
      ).clear(draft)
    else {
      Issue.record("expected a refusal")
      return
    }
    #expect(notAccepted.message.contains("did not accept"))
  }
}
