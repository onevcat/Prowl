import Clocks
import Testing
@testable import supacode

@MainActor
struct ClaudePromptDeliveryTests {
  @Test func waitsForPasteEvidenceBeforeEnter() async {
    let clock = TestClock()
    var observation = ClaudePromptDelivery.Observation(composer: "", editingRevision: nil, hasMarkedText: false)
    var entered = 0
    let delivery = ClaudePromptDelivery(
      observe: { observation },
      insert: { _ in observation = .init(composer: "", editingRevision: 1, hasMarkedText: false); return true },
      submit: { entered += 1; return true }, clock: clock)
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
    var observation = ClaudePromptDelivery.Observation(composer: "", editingRevision: nil, hasMarkedText: false)
    var entered = false
    let delivery = ClaudePromptDelivery(
      observe: { observation },
      insert: { _ in observation = .init(composer: "hello", editingRevision: 1, hasMarkedText: false); return true },
      submit: { entered = true; return true }, clock: clock)
    let task = Task { await delivery.deliver("hello") }
    await clock.advance(by: .milliseconds(50))
    observation = .init(composer: "hello local", editingRevision: 2, hasMarkedText: false)
    await clock.advance(by: .milliseconds(100))
    #expect(await task.value == false)
    #expect(!entered)
  }

  @Test func cancellationAfterPastePreventsEnter() async {
    let clock = TestClock()
    var observation = ClaudePromptDelivery.Observation(composer: "", editingRevision: nil, hasMarkedText: false)
    var inserted = false
    var entered = false
    let delivery = ClaudePromptDelivery(
      observe: { observation },
      insert: { _ in
        inserted = true
        observation = .init(composer: "hello", editingRevision: 1, hasMarkedText: false)
        return true
      },
      submit: { entered = true; return true }, clock: clock)
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
    let delivery = ClaudePromptDelivery(
      observe: { .init(composer: "", editingRevision: nil, hasMarkedText: false) },
      insert: { _ in true }, submit: { entered = true; return true }, clock: clock)
    let task = Task { await delivery.deliver("hello") }
    await clock.advance(by: .seconds(3))
    #expect(await task.value == false)
    #expect(!entered)
  }

  @Test func rejectsDraftAndRequiresExactPasteOrCollapsedMarker() async {
    var inserted = false
    let delivery = ClaudePromptDelivery(
      observe: { .init(composer: "[Image #1]", editingRevision: nil, hasMarkedText: false) },
      insert: { _ in inserted = true; return true }, submit: { true })
    #expect(await delivery.deliver("hello") == false)
    #expect(!inserted)
    #expect(ClaudePromptDelivery.confirmsPaste("[Pasted text #1 +20 lines]", text: "first\nsecond"))
    #expect(!ClaudePromptDelivery.confirmsPaste("hello extra", text: "hello"))
    #expect(!ClaudePromptDelivery.confirmsPaste("[Image #1]", text: "hello"))
  }
}
