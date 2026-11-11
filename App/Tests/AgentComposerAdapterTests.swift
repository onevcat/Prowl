import ProwlCLIShared
import Testing

@testable import Prowl

/// One adapter per agent reads its input box, says how to clear it, and confirms its paste echo
/// (docs-ai 090). The fixtures are VT snapshots as `readStyledSnapshotForCLI` formats them.
struct AgentComposerAdapterTests {
  @Test func registryCoversTheAgentsWithAReadableComposer() {
    #expect(AgentComposerAdapters.adapter(for: .claude)?.agent == .claude)
    #expect(AgentComposerAdapters.adapter(for: .codex)?.agent == .codex)
    #expect(AgentComposerAdapters.adapter(for: .devin)?.agent == .devin)
    for agent in [DetectedAgent.pi, .gemini, .opencode, .amp] {
      #expect(AgentComposerAdapters.adapter(for: agent) == nil)
    }
    #expect(ClaudeComposerAdapter().clearPlan == .stash(key: "ctrl-s"))
    #expect(CodexComposerAdapter().clearPlan == .killLines(key: "ctrl-u"))
    #expect(DevinComposerAdapter().clearPlan == .unsupported)
    // Stashing or killing an image attachment is unverified; a collapsed text paste is not.
    let image = AgentComposerDraft(text: "see [Image #1]", isComplete: false)
    let paste = AgentComposerDraft(text: "[Pasted text #1 +9 lines]", isComplete: false)
    #expect(ClaudeComposerAdapter().clearPlan(for: image) == .unsupported)
    #expect(ClaudeComposerAdapter().clearPlan(for: paste) == .stash(key: "ctrl-s"))
    #expect(CodexComposerAdapter().clearPlan(for: image) == .unsupported)
    let lines = AgentComposerDraft(text: "l1\nl2", isComplete: false)
    #expect(CodexComposerAdapter().clearPlan(for: lines) == .killLines(key: "ctrl-u"))
    let imagePlan = ClaudeComposerAdapter().clearPlan(for: image)
    let imageRefusal = AgentInputRefusal.draft(image, agentName: "Claude", plan: imagePlan)
    #expect(imageRefusal.details?.replaceable == false && imageRefusal.details?.recovery == nil)
    #expect(AgentComposerClearPlan.stash(key: "ctrl-s").recovery == .stash)
    #expect(AgentComposerClearPlan.killLines(key: "ctrl-u").recovery == nil)
    #expect(!AgentComposerClearPlan.unsupported.isSupported)
    // Discard: a draft that must not come back. Claude's stash returns after the next message,
    // so it kills one row; Codex's kill already does not come back; an image stays refused.
    let row = AgentComposerDraft(text: "one row", isComplete: true)
    #expect(ClaudeComposerAdapter().discardPlan(for: row) == .killRow(endKey: "ctrl-e", killKey: "ctrl-u"))
    #expect(ClaudeComposerAdapter().discardPlan(for: paste) == .unsupported)
    #expect(ClaudeComposerAdapter().discardPlan(for: lines) == .unsupported)
    #expect(CodexComposerAdapter().discardPlan(for: lines) == .killLines(key: "ctrl-u"))
    #expect(CodexComposerAdapter().discardPlan(for: image) == .unsupported)
    #expect(DevinComposerAdapter().discardPlan(for: row) == .unsupported)
    #expect(ClaudeComposerAdapter().plan(for: row, policy: .refuse) == .unsupported)
    #expect(ClaudeComposerAdapter().plan(for: row, policy: .replace) == .stash(key: "ctrl-s"))
    #expect(ClaudeComposerAdapter().plan(for: row, policy: .discard).recovery == nil)
    let refusal = AgentInputRefusal.draft(
      row, agentName: "Claude", plan: ClaudeComposerAdapter().clearPlan(for: row), discardable: true)
    #expect(refusal.details?.discardable == true && refusal.details?.recovery == .stash)
  }

  @Test func claudeReadsHintsDraftsAndMarkers() {
    let adapter = ClaudeComposerAdapter()
    func read(_ plain: String, styled: String?) -> AgentComposerReading {
      adapter.read(.init(text: "────────\n" + plain + "\n────────\n  status")) {
        styled.map { "────────\r\n" + $0 + "\r\n────────\r\n  status" }
      }
    }
    #expect(read("❯ ", styled: nil) == .empty)
    // The post-turn prompt suggestion, captured 2026-11-07 with `script -F`.
    #expect(
      read("❯ 找到 build-app 的定义并读一下", styled: "❯\u{A0}\u{1B}[2m找到 build-app 的定义并读一下\u{1B}[22m")
        == .empty)
    #expect(
      read("❯ run the tests", styled: "❯ run the tests")
        == .draft(.init(text: "run the tests", isComplete: true)))
    // A draft over several rows cannot tell a soft wrap from a newline, so it is not complete.
    #expect(
      read("❯ run the\n  tests", styled: "❯ run the\n  tests")
        == .draft(.init(text: "run the\n  tests", isComplete: false)))
    #expect(
      read("❯ [Pasted text #1 +9 lines]", styled: "❯ [Pasted text #1 +9 lines]")
        == .draft(.init(text: "[Pasted text #1 +9 lines]", isComplete: false)))
    #expect(
      read("❯ see [Image #1]", styled: "❯ see [Image #1]")
        == .draft(.init(text: "see [Image #1]", isComplete: false)))
    #expect(read("❯ draft", styled: nil) == .unrecognized)
    #expect(adapter.read(.init(text: "❯ old transcript")) { nil } == .unrecognized)
  }

  @Test func codexReadsPlaceholderSingleAndMultiLineDrafts() {
    let adapter = CodexComposerAdapter()
    let footer =
      "\n  GPT-6-Astra medium · Context 7% used · ~/Sync/github/Prowl · main\n  ← for agents · ? for shortcuts"
    func read(_ composer: String) -> AgentComposerReading {
      adapter.read(.init(text: "")) { "• Worked for 8s\n" + composer + footer }
    }
    #expect(read("› \u{1B}[2mAsk Codex to do anything\u{1B}[0m") == .empty)
    #expect(read("› \u{1B}[2mDescribe what to build next\u{1B}[0m") == .empty)
    #expect(read("› ") == .empty)
    #expect(
      read("› Ask Codex to do anything")
        == .draft(.init(text: "Ask Codex to do anything", isComplete: true)))
    // Rows keep their indentation past the two-column margin and interior blank rows; a draft
    // over several rows cannot tell a soft wrap from a newline, so it is not complete.
    #expect(read("› l1\n  l2\n  l3") == .draft(.init(text: "l1\nl2\nl3", isComplete: false)))
    #expect(
      read("› if ready:\n      run()\n\n  print(1)\n")
        == .draft(.init(text: "if ready:\n    run()\n\nprint(1)", isComplete: false)))
    #expect(read("›   indented") == .draft(.init(text: "  indented", isComplete: true)))
    // Astra's dim stars around a one-row draft are decoration, never text to carry over, and
    // a star next to a word cannot be told from a space (review R090-004).
    #expect(
      read("›\u{1B}[2m⠁\u{1B}[22mreview the tests\u{1B}[2m⡀\u{1B}[22m")
        == .draft(.init(text: "review the tests", isComplete: false)))
    #expect(read("›\u{1B}[2m⠁⠂\u{1B}[22m") == .empty)
    // A box that takes no input (Codex's parent-owned sub-agent view) is never empty, and a dim
    // paste chip is content like an image (review of #1071, R1).
    #expect(read("› \u{1B}[2mViewing sub-agent — direct input is disabled\u{1B}[0m") == .unrecognized)
    #expect(
      read("› \u{1B}[2m[Pasted Content 12 chars]\u{1B}[0m")
        == .draft(.init(text: "[Pasted Content 12 chars]", isComplete: false)))
    #expect(read("› ⠁⠂") == .draft(.init(text: "", isComplete: false)))
    // A draft row that mentions paths does not end the box: the footer is the last such row
    // (review R090-005).
    #expect(
      read("› Compare these files:\n  src/main.swift · /tmp/old.swift\n  other.swift")
        == .draft(
          .init(text: "Compare these files:\nsrc/main.swift · /tmp/old.swift\nother.swift", isComplete: false)))
    #expect(
      read("› \u{1B}[2m[Image #1]\u{1B}[0m") == .draft(.init(text: "[Image #1]", isComplete: false))
    )
    #expect(
      read("› see [Pasted Content 12 chars]")
        == .draft(.init(text: "see [Pasted Content 12 chars]", isComplete: false)))
    // Codex 0.167 keeps the status line below a steered draft while a turn runs.
    #expect(
      adapter.read(.init(text: "")) {
        "• Working (4s • esc to interrupt)\n› steer" + footer + "\n  tab to queue message"
      }
        == .draft(.init(text: "steer", isComplete: true)))
    #expect(adapter.read(.init(text: "")) { "› draft\n\n  no footer here" } == .unrecognized)
    #expect(adapter.read(.init(text: "")) { nil } == .unrecognized)
    #expect(adapter.read(.init(text: "")) { "\u{1B}]unterminated" } == .unrecognized)
    #expect(
      CodexScreenProfile.composerHasNoDraft(styledSnapshot: "› \u{1B}[2mhint\u{1B}[0m" + footer))
  }

  @Test func devinReadsThePlainScreenOnly() {
    let adapter = DevinComposerAdapter()
    var styledReads = 0
    let idle = AgentScreenSnapshot(
      text:
        "────────\n❭ Ask Devin to build features, fix bugs, or work on your code\n────────\nstatus")
    #expect(
      adapter.read(idle) {
        styledReads += 1
        return nil
      } == .empty)
    let draft = AgentScreenSnapshot(text: "────────\n❭ first line\nsecond line\n────────\nstatus")
    #expect(
      adapter.read(draft) { nil }
        == .draft(.init(text: "first line\nsecond line", isComplete: false)))
    let oneRow = AgentScreenSnapshot(text: "────────\n❭ next prompt\n────────\nstatus")
    #expect(adapter.read(oneRow) { nil } == .draft(.init(text: "next prompt", isComplete: true)))
    #expect(adapter.read(.init(text: "❭ 1 Yes\n↑↓ select · esc cancel")) { nil } == .unrecognized)
    #expect(styledReads == 0)
  }

  @Test func pasteEchoRulesStayPerAgent() {
    let claude = ClaudeComposerAdapter()
    #expect(claude.confirmsPaste("[Pasted text #1 +20 lines]", text: "first\nsecond"))
    #expect(claude.confirmsPaste("这是一段\n中文", text: "这是一段中文"))
    #expect(!claude.confirmsPaste("这是 一段\n  中文", text: "这是一段中文"))
    let devin = DevinComposerAdapter()
    #expect(
      devin.confirmsPaste(
        "run CBA7CC1B-\nCDB8 --invocation\n2", text: "run CBA7CC1B-CDB8 --invocation 2"))
    #expect(!devin.confirmsPaste("[Pasted text #1 +20 lines]", text: "hello"))
    let codex = CodexComposerAdapter()
    #expect(codex.confirmsPaste("hello\n  world", text: "hello world"))
    #expect(!codex.confirmsPaste("[Pasted text #1 +20 lines]", text: "hello"))
  }
}
