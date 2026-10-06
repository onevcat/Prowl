import Clocks
import Testing

@testable import Prowl

@MainActor
struct AgentPromptDeliveryTests {
  @Test func devinAcknowledgesWrapsInsideTokensWithoutIgnoringEditedSpaces() {
    #expect(
      AgentPromptDelivery.confirmsPaste(
        "run CBA7CC1B-\nCDB8 --invocation\n2", text: "run CBA7CC1B-CDB8 --invocation 2",
        acceptsSoftWrappedWords: true))
    #expect(
      !AgentPromptDelivery.confirmsPaste(
        "run CBA7CC1B- CDB8", text: "run CBA7CC1B-CDB8", acceptsSoftWrappedWords: true))
    #expect(
      !AgentPromptDelivery.confirmsPaste(
        "run CBA7CC1B-\nOTHER", text: "run CBA7CC1B-CDB8", acceptsSoftWrappedWords: true))
  }
  @Test func runFenceAfterPastePreventsEnter() async {
    let clock = TestClock()
    let fence = RunFence()
    var composer = ""
    var entered = false
    let delivery = AgentPromptDelivery(
      observe: {
        fence.isLive ? .init(composer: composer, editingRevision: nil, hasMarkedText: false) : nil
      },
      insert: {
        composer = $0
        return true
      },
      submit: {
        entered = true
        return true
      }, clock: clock)
    let task = Task { await delivery.deliver("hello") }
    await clock.advance(by: .milliseconds(50))
    #expect(composer == "hello")
    fence.isLive = false
    await clock.advance(by: .milliseconds(100))
    #expect(await task.value == false)
    #expect(!entered)
  }

  @MainActor
  private final class RunFence {
    var isLive = true
  }

  @Test func onlyClaudeAcceptsItsCollapsedPasteMarker() {
    #expect(!AgentPromptDelivery.confirmsPaste("[Pasted text #1 +20 lines]", text: "hello"))
    #expect(AgentPromptDelivery.confirmsPaste("hello\n  world", text: "hello world"))
  }

  @Test func waitsForPasteEvidenceBeforeEnter() async {
    let clock = TestClock()
    var observation = AgentPromptDelivery.Observation(
      composer: "", editingRevision: nil, hasMarkedText: false)
    var entered = 0
    let delivery = AgentPromptDelivery(
      observe: { observation },
      insert: { _ in
        observation = .init(composer: "", editingRevision: 1, hasMarkedText: false)
        return true
      },
      submit: {
        entered += 1
        return true
      }, clock: clock)
    let task = Task { await delivery.deliver("first\nsecond") }
    await clock.advance(by: .milliseconds(100))
    #expect(entered == 0)
    observation = .init(composer: "first\n  second", editingRevision: 1, hasMarkedText: false)
    await clock.advance(by: .milliseconds(100))
    #expect(await task.value)
    #expect(entered == 1)
  }

  @Test func localEditAfterPastePreventsEnter() async {
    let clock = TestClock()
    var observation = AgentPromptDelivery.Observation(
      composer: "", editingRevision: nil, hasMarkedText: false)
    var entered = false
    let delivery = AgentPromptDelivery(
      observe: { observation },
      insert: { _ in
        observation = .init(composer: "hello", editingRevision: 1, hasMarkedText: false)
        return true
      },
      submit: {
        entered = true
        return true
      }, clock: clock)
    let task = Task { await delivery.deliver("hello") }
    await clock.advance(by: .milliseconds(50))
    observation = .init(composer: "hello local", editingRevision: 2, hasMarkedText: false)
    await clock.advance(by: .milliseconds(100))
    #expect(await task.value == false)
    #expect(!entered)
  }

  @Test func cancellationAfterPastePreventsEnter() async {
    let clock = TestClock()
    var observation = AgentPromptDelivery.Observation(
      composer: "", editingRevision: nil, hasMarkedText: false)
    var inserted = false
    var entered = false
    let delivery = AgentPromptDelivery(
      observe: { observation },
      insert: { _ in
        inserted = true
        observation = .init(composer: "hello", editingRevision: 1, hasMarkedText: false)
        return true
      },
      submit: {
        entered = true
        return true
      }, clock: clock)
    let task = Task { await delivery.deliver("hello") }
    await clock.advance(by: .milliseconds(50))
    #expect(inserted)
    task.cancel()
    #expect(await task.value == false)
    #expect(!entered)
  }

  @Test func missingEchoTimesOutWithoutEnter() async {
    let clock = TestClock()
    var entered = false
    let delivery = AgentPromptDelivery(
      observe: { .init(composer: "", editingRevision: nil, hasMarkedText: false) },
      insert: { _ in true },
      submit: {
        entered = true
        return true
      }, clock: clock)
    let task = Task { await delivery.deliver("hello") }
    await clock.advance(by: .seconds(3))
    #expect(await task.value == false)
    #expect(!entered)
  }

  @Test func rejectsDraftAndRequiresExactPasteOrCollapsedMarker() async {
    var inserted = false
    let delivery = AgentPromptDelivery(
      observe: { .init(composer: "[Image #1]", editingRevision: nil, hasMarkedText: false) },
      insert: { _ in
        inserted = true
        return true
      }, submit: { true })
    #expect(await delivery.deliver("hello") == false)
    #expect(!inserted)
    #expect(
      AgentPromptDelivery.confirmsPaste(
        "[Pasted text #1 +20 lines]", text: "first\nsecond", acceptsClaudePasteMarker: true))
    #expect(!AgentPromptDelivery.confirmsPaste("hello extra", text: "hello"))
    #expect(!AgentPromptDelivery.confirmsPaste("[Image #1]", text: "hello"))
  }
}
