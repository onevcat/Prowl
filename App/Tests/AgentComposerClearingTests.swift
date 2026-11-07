import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

/// The clearing executor presses the adapter's plan under the key guard and only reports the
/// box cleared when it re-reads as empty (docs-ai 090). The screen double behaves like the real
/// surface: Prowl's own control keys count in the input generation but never move the editing
/// stamp (`TerminalEditingActivity`), so a moved stamp is always someone typing on the Mac.
@MainActor
struct AgentComposerClearingTests {
  private final class Screen {
    var reading: AgentComposerReading?
    var hasMarkedText = false
    var editingRevision: TimeInterval? = 1
    var inputGeneration: UInt64 = 10
    var pressed: [String] = []
    var accepts = true
    /// What each press leaves in the box, in order; the last entry repeats.
    var responses: [AgentComposerReading?] = []
    /// Runs on every observation, so a test can slip local activity in at an exact point.
    var onObserve: ((Screen) -> Void)?

    init(_ reading: AgentComposerReading) { self.reading = reading }

    func observation() -> AgentComposerClearing.Observation {
      onObserve?(self)
      return .init(
        reading: reading, hasMarkedText: hasMarkedText, editingRevision: editingRevision,
        inputGeneration: inputGeneration)
    }

    func press(_ key: String) -> Bool {
      pressed.append(key)
      guard accepts else { return false }
      inputGeneration += 1
      if !responses.isEmpty { reading = responses.removeFirst() }
      return true
    }

    /// Someone typed printable text on the Mac.
    func typeLocally() {
      inputGeneration += 1
      editingRevision = (editingRevision ?? 0) + 40
    }

    /// Someone pressed a history or control key on the Mac.
    func pressLocally() {
      inputGeneration += 1
    }
  }

  private func clearing(
    _ screen: Screen, plan: AgentComposerClearPlan, clock: TestClock<Duration>, observeNil: Bool = false
  ) -> AgentComposerClearing {
    AgentComposerClearing(
      observe: { observeNil ? nil : screen.observation() }, press: { screen.press($0) },
      plan: plan, agentName: "Claude", clock: clock, now: { 100 })
  }

  private func expectRefusal(_ outcome: AgentComposerClearing.Outcome) -> AgentInputRefusal? {
    if case .refused(let refusal) = outcome { return refusal }
    Issue.record("expected a refusal, got \(outcome)")
    return nil
  }

  @Test(.timeLimit(.minutes(1))) func stashPressesOnceAndReportsTheRecovery() async {
    let clock = TestClock()
    let screen = Screen(.draft(.init(text: "hello", isComplete: true)))
    screen.responses = [.empty]
    let outcome = await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock)
      .clear(.init(text: "hello", isComplete: true))
    #expect(outcome == .cleared(.init(text: "hello", isComplete: true, recovery: .stash)))
    #expect(screen.pressed == ["ctrl-s"])
  }

  @Test(.timeLimit(.minutes(1))) func aKeyThatDoesNotEmptyTheBoxIsAPartialClearRefusal() async {
    let clock = TestClock()
    let screen = Screen(.draft(.init(text: "hello", isComplete: true)))
    let task = Task {
      await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock).clear(.init(text: "hello", isComplete: true))
    }
    await clock.advance(by: .seconds(2))
    let refusal = expectRefusal(await task.value)
    #expect(refusal?.details?.reason == .clearing)
    #expect(refusal?.details?.replaceable == false)
    #expect(refusal?.details?.draft?.text == "hello")
    #expect(screen.pressed == ["ctrl-s"])
  }

  @Test(.timeLimit(.minutes(1))) func killLinesStopsAtTheFirstEmptyReadingAndCapsPresses() async {
    let clock = TestClock()
    let draft = AgentComposerDraft(text: "l1\nl2\nl3", isComplete: false)
    let screen = Screen(.draft(draft))
    // Codex removes a line's text with one press and its newline with the next.
    screen.responses = [
      .draft(.init(text: "l1\nl2\n", isComplete: false)), .draft(.init(text: "l1\nl2", isComplete: false)),
      .draft(.init(text: "l1\n", isComplete: false)), .draft(.init(text: "l1", isComplete: true)), .empty,
    ]
    let outcome = await clearing(screen, plan: .killLines(key: "ctrl-u"), clock: clock).clear(draft)
    #expect(outcome == .cleared(.init(text: "l1\nl2\nl3", isComplete: false, recovery: nil)))
    #expect(screen.pressed.count == 5)

    let stubborn = Screen(.draft(draft))
    let capped = Task { await clearing(stubborn, plan: .killLines(key: "ctrl-u"), clock: clock).clear(draft) }
    await clock.advance(by: .seconds(20))
    let refusal = expectRefusal(await capped.value)
    #expect(refusal?.details?.reason == .clearing)
    #expect(stubborn.pressed.count == AgentComposerClearing.maximumPresses(forLines: 3))
    #expect(AgentComposerClearing.maximumPresses(forLines: 1) == 4)
    #expect(AgentComposerClearing.maximumPresses(forLines: 100) == 64)
  }

  /// Someone typing on the Mac while Prowl waits for its first key to redraw stops the sequence
  /// before another key goes in (review R090-001).
  @Test(.timeLimit(.minutes(1))) func typingOnTheMacDuringTheSettleWaitStopsTheSequence() async {
    let clock = TestClock()
    let draft = AgentComposerDraft(text: "l1\nl2", isComplete: false)
    let screen = Screen(.draft(draft))
    // The first key shows no change yet, so the executor waits for the screen.
    let task = Task { await clearing(screen, plan: .killLines(key: "ctrl-u"), clock: clock).clear(draft) }
    await clock.advance(by: .milliseconds(100))
    screen.typeLocally()
    screen.reading = .draft(.init(text: "l1\nl2x", isComplete: false))
    await clock.advance(by: .seconds(2))
    let refusal = expectRefusal(await task.value)
    #expect(refusal?.details?.reason == .editing)
    #expect(refusal?.message.contains("partly cleared") == true)
    #expect(screen.pressed == ["ctrl-u"])

    let composing = Screen(.draft(draft))
    composing.hasMarkedText = true
    let first = expectRefusal(await clearing(composing, plan: .killLines(key: "ctrl-u"), clock: clock).clear(draft))
    #expect(first?.details?.reason == .editing)
    #expect(composing.pressed.isEmpty)
  }

  /// A key that is not Prowl's own, landing with the reading that first shows the box empty,
  /// means someone else emptied or replaced it: no success, and nothing is sent.
  @Test(.timeLimit(.minutes(1))) func aLocalKeyCoincidingWithTheEmptyReadingRefuses() async {
    let clock = TestClock()
    let draft = AgentComposerDraft(text: "hello", isComplete: true)
    let screen = Screen(.draft(draft))
    var observations = 0
    screen.onObserve = { screen in
      observations += 1
      // After Prowl's key was recorded, a local history key replaces the box with nothing.
      if observations == 3 {
        screen.pressLocally()
        screen.reading = .empty
      }
    }
    let task = Task { await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock).clear(draft) }
    await clock.advance(by: .seconds(2))
    let refusal = expectRefusal(await task.value)
    #expect(refusal?.details?.reason == .editing)
    #expect(screen.pressed == ["ctrl-s"])

    // Prowl's own key, and only it, may empty the box.
    let own = Screen(.draft(draft))
    own.responses = [.empty]
    let outcome = await clearing(own, plan: .stash(key: "ctrl-s"), clock: clock).clear(draft)
    #expect(outcome == .cleared(.init(text: "hello", isComplete: true, recovery: .stash)))
  }

  @Test(.timeLimit(.minutes(1))) func unsupportedPlanRefusesWithoutPressingAndAGoneScreenRefuses() async {
    let clock = TestClock()
    let draft = AgentComposerDraft(text: "hello", isComplete: true)
    let screen = Screen(.draft(draft))
    let refused = expectRefusal(await clearing(screen, plan: .unsupported, clock: clock).clear(draft))
    #expect(refused?.details?.reason == .draft)
    #expect(refused?.details?.replaceable == false)
    #expect(screen.pressed.isEmpty)

    let gone = expectRefusal(
      await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock, observeNil: true).clear(draft))
    #expect(gone?.message.contains("no longer available") == true)

    screen.accepts = false
    let notAccepted = expectRefusal(await clearing(screen, plan: .stash(key: "ctrl-s"), clock: clock).clear(draft))
    #expect(notAccepted?.message.contains("did not accept") == true)
  }
}
