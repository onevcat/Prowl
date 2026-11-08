import AppKit
import Clocks
import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import Prowl

@MainActor
struct AgentPromptDeliveryTests {
  @Test func devinAcknowledgesWrapsInsideTokensWithoutIgnoringEditedSpaces() {
    #expect(
      AgentPromptDelivery.confirmsPaste(
        "run CBA7CC1B-\nCDB8 --invocation\n2", text: "run CBA7CC1B-CDB8 --invocation 2",
        adapter: DevinComposerAdapter()))
    #expect(
      !AgentPromptDelivery.confirmsPaste(
        "run CBA7CC1B- CDB8", text: "run CBA7CC1B-CDB8", adapter: DevinComposerAdapter()))
    #expect(
      !AgentPromptDelivery.confirmsPaste(
        "run CBA7CC1B-\nOTHER", text: "run CBA7CC1B-CDB8", adapter: DevinComposerAdapter()))
    #expect(
      !AgentPromptDelivery.confirmsPaste(
        "[Pasted text #1 +20 lines]", text: "hello", adapter: DevinComposerAdapter()))
  }
  @Test func onlyRuntimesThatDropEarlyEnterWaitOutsideDispatch() {
    #expect(AgentComposerAdapters.adapter(for: .pi) == nil)
    let codex = CodexComposerAdapter()
    #expect(codex.pasteConfirmation(for: .dispatch) == nil)
    #expect(codex.pasteConfirmation(for: .send) == nil)
    let claude = ClaudeComposerAdapter()
    #expect(claude.pasteConfirmation(for: .dispatch) == .required)
    #expect(claude.pasteConfirmation(for: .workflowMessage) == nil)
    #expect(claude.pasteConfirmation(for: .send) == nil)
    let devin = DevinComposerAdapter()
    #expect(devin.pasteConfirmation(for: .dispatch) == .required)
    #expect(devin.pasteConfirmation(for: .workflowMessage) == .required)
    #expect(devin.dropsEarlyEnter && !claude.dropsEarlyEnter && !codex.dropsEarlyEnter)
  }

  /// `prowl send` must still answer Devin menus and append to drafts, where the input box is not empty.
  @Test func devinSendWaitsOnlyForAnEmptyComposer() {
    #expect(DevinComposerAdapter().pasteConfirmation(for: .send) == .whenComposerIsEmpty)
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
    #expect(
      AgentPromptDelivery.confirmsPaste(composer, text: text, adapter: ClaudeComposerAdapter()))
    #expect(
      !AgentPromptDelivery.confirmsPaste(
        composer, text: text + "多", adapter: ClaudeComposerAdapter()))
    #expect(
      !AgentPromptDelivery.confirmsPaste(
        "这是 一段\n  中文", text: "这是一段中文", adapter: ClaudeComposerAdapter()))
  }

  /// Only the line Prowl itself left unsent, with no input since, goes in with Enter alone. A
  /// draft that merely looks the same on screen (a collapsed paste marker, collapsed whitespace)
  /// is someone else's and refuses (PR #1057 review R1, R2).
  @Test func onlyProwlsOwnUnsentLineIsSubmittedAsIs() async {
    var inserted: [String] = []
    var submitted = 0
    func delivery(_ composer: String, unsent: AgentUnsentLine?, generation: UInt64 = 5)
      -> AgentPromptDelivery
    {
      AgentPromptDelivery(
        observe: {
          .init(
            composer: composer, editingRevision: nil, hasMarkedText: false,
            inputGeneration: generation)
        },
        insert: {
          inserted.append($0)
          return true
        },
        submit: {
          submitted += 1
          return true
        }, adapter: ClaudeComposerAdapter(), unsent: unsent)
    }
    let text = "请只回复明白两个字。"
    let left = AgentUnsentLine(text: text, inputGeneration: 5)
    #expect(await delivery("请只回复明白两个\n  字。", unsent: left).deliver(text) == .submitted)
    #expect(inserted.isEmpty && submitted == 1)
    // Any input since Prowl left it, such as ⌃U or a history key.
    #expect(
      await delivery("请只回复明白两个\n  字。", unsent: left, generation: 6).deliver(text) == .notInserted)
    // Someone's own paste: the marker hides its content.
    let marker = "[Pasted text #1 +20 lines]"
    #expect(await delivery(marker, unsent: nil).deliver("Only reply hello") == .notInserted)
    // Prowl's own multiline paste, collapsed to a marker.
    let pasted = AgentUnsentLine(text: "first\nsecond", inputGeneration: 5)
    #expect(await delivery(marker, unsent: pasted).deliver("first\nsecond") == .submitted)
    // A different request whose text only differs in whitespace.
    let spaced = AgentUnsentLine(text: "exactly 'a  b'", inputGeneration: 5)
    #expect(
      await delivery("exactly 'a b'", unsent: spaced).deliver("exactly 'a b'") == .notInserted)
    #expect(inserted.isEmpty && submitted == 2)
  }

  /// The record is taken right after Prowl's insertion. An edit that ends the delivery must not
  /// become the provenance of a later retry (PR #1057 review R4).
  @Test func anEditThatEndsTheDeliveryIsNeverResumed() async {
    let clock = TestClock()
    var step = 0
    var recorded: AgentUnsentLine?
    var submitted = 0
    let text = "first\nsecond"
    let marker = "[Pasted text #1 +20 lines]"
    let first = AgentPromptDelivery(
      observe: {
        defer { step += 1 }
        switch step {
        case 0:
          return .init(composer: "", editingRevision: 1, hasMarkedText: false, inputGeneration: 1)
        case 1:
          return .init(composer: "", editingRevision: 2, hasMarkedText: false, inputGeneration: 2)
        // Someone replaced the box on the Mac while Prowl waited for the echo.
        default:
          return .init(
            composer: marker, editingRevision: 3, hasMarkedText: false, inputGeneration: 3)
        }
      },
      insert: { _ in true },
      submit: {
        submitted += 1
        return true
      }, clock: clock, adapter: ClaudeComposerAdapter(), onUnsent: { recorded = $0 })
    let task = Task { await first.deliver(text) }
    await clock.advance(by: .milliseconds(100))
    #expect(await task.value == .notSubmitted)
    #expect(recorded == AgentUnsentLine(text: text, inputGeneration: 2))
    let retry = AgentPromptDelivery(
      observe: {
        .init(composer: marker, editingRevision: 3, hasMarkedText: false, inputGeneration: 3)
      },
      insert: { _ in true },
      submit: {
        submitted += 1
        return true
      }, adapter: ClaudeComposerAdapter(), unsent: recorded)
    #expect(await retry.deliver(text) == .notInserted)
    #expect(submitted == 0)
  }

  /// Input that leaves the editing timestamp alone (a history key) can still swap the box
  /// during the echo wait; the first delivery must not press Enter then (PR #1057 review R6).
  @Test func inputDuringTheEchoWaitStopsTheDelivery() async {
    let clock = TestClock()
    var step = 0
    var submitted = 0
    let delivery = AgentPromptDelivery(
      observe: {
        defer { step += 1 }
        switch step {
        case 0:
          return .init(composer: "", editingRevision: 1, hasMarkedText: false, inputGeneration: 1)
        case 1:
          return .init(composer: "", editingRevision: 2, hasMarkedText: false, inputGeneration: 2)
        default:
          return .init(
            composer: "[Pasted text #2 +9 lines]", editingRevision: 2, hasMarkedText: false,
            inputGeneration: 3)
        }
      },
      insert: { _ in true },
      submit: {
        submitted += 1
        return true
      }, clock: clock, adapter: ClaudeComposerAdapter())
    let task = Task { await delivery.deliver("first\nsecond") }
    await clock.advance(by: .milliseconds(100))
    #expect(await task.value == .notSubmitted)
    #expect(submitted == 0)
  }

  /// Ghostty binding actions such as `csi:` and `text:` write to the pty directly; they count as
  /// input too (PR #1057 review R7).
  @Test func bindingActionsCountAsInput() {
    let view = GhosttySurfaceView(
      runtime: GhosttyRuntime(), workingDirectory: URL(fileURLWithPath: "/tmp"), fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB, skipsSurfaceCreationForTesting: true)
    let start = view.inputGeneration
    view.performBindingAction("csi:A")
    view.performBindingAction("text:hello")
    #expect(view.inputGeneration == start + 2)
  }

  @Test func aDraftRefusalQuotesTheDraftAndSaysWhetherItCanBeReplaced() {
    let claude = ClaudeComposerAdapter()
    let left = AgentUnsentLine(text: "hello", inputGeneration: 5)
    #expect(left.resumes("hello", composer: "hel\n  lo", inputGeneration: 5, adapter: claude))
    #expect(!left.resumes("hello", composer: "hel\n  lo", inputGeneration: 6, adapter: claude))
    #expect(
      !left.resumes(
        "Only reply hello", composer: "[Pasted text #1 +20 lines]", inputGeneration: 5,
        adapter: claude))

    let refusal = AgentInputRefusal.draft(
      .init(text: "git push --force origin main", isComplete: true), agentName: "Claude",
      plan: claude.clearPlan)
    #expect(refusal.message.contains("git push --force"))
    #expect(refusal.details?.reason == .draft)
    #expect(refusal.details?.replaceable == true)
    #expect(refusal.details?.recovery == .stash)
    #expect(refusal.details?.draft == .init(text: "git push --force origin main", isComplete: true))
    let long = String(repeating: "长", count: 80)
    let truncated = AgentInputRefusal.draft(
      .init(text: long, isComplete: true), agentName: "Codex", plan: .killLines(key: "ctrl-u"))
    #expect(truncated.message.count < 160)
    #expect(truncated.details?.replaceable == true && truncated.details?.recovery == nil)
    let fixed = AgentInputRefusal.draft(
      .init(text: "draft", isComplete: true), agentName: "Devin", plan: .unsupported)
    #expect(fixed.details?.replaceable == false)
  }

  /// Keys that clear, recall or submit a line count as input, though they are not editing keys
  /// for the local-edit guard (PR #1057 review R5).
  @Test func everyKeyPressCountsAsInput() throws {
    let view = GhosttySurfaceView(
      runtime: GhosttyRuntime(), workingDirectory: URL(fileURLWithPath: "/tmp"), fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB, skipsSurfaceCreationForTesting: true)
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
          context: nil,
          characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
          keyCode: keyCode))
      view.keyDown(with: event)
    }
    let start = view.inputGeneration
    try press("\u{15}", keyCode: 32, modifiers: .control)  // ⌃U
    try press("\u{F700}", keyCode: 126)  // Up
    try press("\r", keyCode: 36)  // Return
    #expect(view.inputGeneration == start + 3)
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
      AgentPromptDelivery.confirmsPaste(
        "[Pasted text #1 +20 lines]", text: "first\nsecond", adapter: ClaudeComposerAdapter()))
    #expect(!AgentPromptDelivery.confirmsPaste("hello extra", text: "hello"))
    #expect(!AgentPromptDelivery.confirmsPaste("[Image #1]", text: "hello"))
  }
}
