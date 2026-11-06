import Clocks
import Foundation
import Testing

@testable import Prowl

@MainActor
struct AgentPromptDeliveryTests {
  @Test func devinAcknowledgesWrapsInsideTokensWithoutIgnoringEditedSpaces() {
    #expect(
      AgentPromptDelivery.confirmsPaste(
        "run CBA7CC1B-\nCDB8 --invocation\n2", text: "run CBA7CC1B-CDB8 --invocation 2",
        profile: .devin))
    #expect(
      !AgentPromptDelivery.confirmsPaste("run CBA7CC1B- CDB8", text: "run CBA7CC1B-CDB8", profile: .devin))
    #expect(
      !AgentPromptDelivery.confirmsPaste("run CBA7CC1B-\nOTHER", text: "run CBA7CC1B-CDB8", profile: .devin))
    #expect(
      !AgentPromptDelivery.confirmsPaste("[Pasted text #1 +20 lines]", text: "hello", profile: .devin))
  }
  @Test func onlyRuntimesThatDropEarlyEnterWaitOutsideDispatch() {
    #expect(AgentComposerProfile(agent: .codex) == nil)
    #expect(AgentComposerProfile(agent: .pi) == nil)
    #expect(AgentComposerProfile.claude.pasteConfirmation(for: .dispatch) == .required)
    #expect(AgentComposerProfile.claude.pasteConfirmation(for: .workflowMessage) == nil)
    #expect(AgentComposerProfile.claude.pasteConfirmation(for: .send) == nil)
    #expect(AgentComposerProfile.devin.pasteConfirmation(for: .dispatch) == .required)
    #expect(AgentComposerProfile.devin.pasteConfirmation(for: .workflowMessage) == .required)
  }

  /// `prowl send` must still answer Devin menus and append to drafts, where the input box is not empty.
  @Test func devinSendWaitsOnlyForAnEmptyComposer() {
    #expect(AgentComposerProfile.devin.pasteConfirmation(for: .send) == .whenComposerIsEmpty)
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
    #expect(await task.value == .notSubmitted)
    #expect(!entered)
  }

  @MainActor
  private final class RunFence {
    var isLive = true
  }

  /// Claude wraps CJK text between two characters, so the screen has a line break where the text
  /// has none. The echo still confirms; spaces inside a row must still match (mirror input that
  /// stayed unsent, 2026-11-06).
  @Test func claudeAcknowledgesTextWrappedBetweenCharacters() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "Fixtures/AgentScreenDetection/claude/2.1.319/idle/cjk-wrapped-draft.txt")
    let screen = AgentScreenSnapshot(text: try String(contentsOf: url, encoding: .utf8))
    let composer = try #require(ClaudeScreenProfile.composerContents(in: screen))
    let text =
      "这是第三条复现消息，故意写得比上一条更长一些，长到在这个宽度的输入框里一定会在两个汉字之间折成两行显示，"
      + "但是又不会长到被收成粘贴占位符，请只回复明白两个字。"
    #expect(composer.contains("\n"))
    #expect(AgentPromptDelivery.confirmsPaste(composer, text: text, profile: .claude))
    #expect(!AgentPromptDelivery.confirmsPaste(composer, text: text + "多", profile: .claude))
    #expect(!AgentPromptDelivery.confirmsPaste("这是 一段\n  中文", text: "这是一段中文", profile: .claude))
  }

  /// Only the line Prowl itself left unsent, untouched since, goes in with Enter alone. A draft
  /// that merely looks the same on screen (a collapsed paste marker, collapsed whitespace) is
  /// someone else's and refuses (PR #1057 review R1, R2).
  @Test func onlyProwlsOwnUnsentLineIsSubmittedAsIs() async {
    var inserted: [String] = []
    var submitted = 0
    func delivery(_ composer: String, unsent: AgentUnsentLine?, revision: TimeInterval? = 5) -> AgentPromptDelivery {
      AgentPromptDelivery(
        observe: { .init(composer: composer, editingRevision: revision, hasMarkedText: false) },
        insert: {
          inserted.append($0)
          return true
        },
        submit: {
          submitted += 1
          return true
        }, profile: .claude, unsent: unsent)
    }
    let text = "请只回复明白两个字。"
    let left = AgentUnsentLine(text: text, editingRevision: 5)
    #expect(await delivery("请只回复明白两个\n  字。", unsent: left).deliver(text) == .submitted)
    #expect(inserted.isEmpty && submitted == 1)
    // Edited since Prowl left it.
    #expect(await delivery("请只回复明白两个\n  字。", unsent: left, revision: 6).deliver(text) == .notInserted)
    // Someone's own paste: the marker hides its content.
    let marker = "[Pasted text #1 +20 lines]"
    #expect(await delivery(marker, unsent: nil).deliver("Only reply hello") == .notInserted)
    // Prowl's own multiline paste, collapsed to a marker.
    let pasted = AgentUnsentLine(text: "first\nsecond", editingRevision: 5)
    #expect(await delivery(marker, unsent: pasted).deliver("first\nsecond") == .submitted)
    // A different request whose text only differs in whitespace.
    let spaced = AgentUnsentLine(text: "exactly 'a  b'", editingRevision: 5)
    #expect(await delivery("exactly 'a b'", unsent: spaced).deliver("exactly 'a b'") == .notInserted)
    #expect(inserted.isEmpty && submitted == 2)
  }

  @Test func aDraftRefusalQuotesTheDraftUnlessItIsProwlsOwnUnsentLine() {
    let profile = AgentComposerProfile.claude
    let left = AgentUnsentLine(text: "hello", editingRevision: 5)
    #expect(profile.draftRefusal("", delivering: "hello", unsent: nil, editingRevision: 5) == nil)
    #expect(profile.draftRefusal("hel\n  lo", delivering: "hello", unsent: left, editingRevision: 5) == nil)
    #expect(profile.draftRefusal("hel\n  lo", delivering: "hello", unsent: left, editingRevision: 6) != nil)
    #expect(profile.draftRefusal("hello", delivering: "hello", unsent: nil, editingRevision: 5) != nil)
    #expect(
      profile.draftRefusal(
        "[Pasted text #1 +20 lines]", delivering: "Only reply hello", unsent: nil, editingRevision: 5)
        != nil)
    let refusal = profile.draftRefusal(
      "git push --force origin main", delivering: "hello", unsent: nil, editingRevision: 5)
    #expect(refusal?.contains("git push --force") == true)
    let long = String(repeating: "长", count: 80)
    #expect((profile.draftRefusal(long, delivering: nil, unsent: nil, editingRevision: nil)?.count ?? 0) < 160)
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
    #expect(await task.value == .submitted)
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
    #expect(await task.value == .notSubmitted)
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
    #expect(await task.value == .notSubmitted)
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
    #expect(await task.value == .notSubmitted)
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
    #expect(await delivery.deliver("hello") == .notInserted)
    #expect(!inserted)
    #expect(
      AgentPromptDelivery.confirmsPaste("[Pasted text #1 +20 lines]", text: "first\nsecond", profile: .claude))
    #expect(!AgentPromptDelivery.confirmsPaste("hello extra", text: "hello"))
    #expect(!AgentPromptDelivery.confirmsPaste("[Image #1]", text: "hello"))
  }
}
