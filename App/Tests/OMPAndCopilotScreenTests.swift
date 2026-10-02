import Testing

@testable import supacode

struct OMPAndCopilotScreenTests {
  @Test(arguments: ["󱊷", "⎋", "esc"])
  func ompRecognizesLeadingEscapeHint(prefix: String) {
    let screen = """
      What's New
      Updated to v18.1.10
      ────────────────────────────
      Hello

        \(prefix) Working…

      ╭── ⠦ 2s · model · ~/project ──╮
      ╰─                            ─╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .working)
    #expect(DetectedAgent.pi.detectState(in: screen) == .idle)
  }

  @Test func ompDoesNotTreatQuotedOrStaleEscapeHintAsWorking() {
    for screen in [
      "The status says 󱊷 Working… while processing.",
      "󱊷 Working…\nResult\nOne\nTwo\nThree\nFour\nReady",
      "󱊷 Working… is the status label",
    ] {
      #expect(DetectedAgent.omp.detectState(in: screen) == .idle)
    }
  }

  @Test func copilotRecognizesWorkingInterruptFooter() {
    let screen = """
      ~/project [⎇ main] [#123]                   Session: 0 AIC used

      ◎ Working esc interrupt                   gpt-5.1-codex-max
      """
    #expect(DetectedAgent.copilot.detectState(in: screen) == .working)
  }

  @Test(arguments: ["∙", "∘", "○", "◎", "◉"], ["", " · 101 B", " · 1.2 KB", " · 12.3 MB"])
  func copilotRecognizesEveryWorkingFrameAndByteCount(frame: String, byteCount: String) {
    let screen = """
      ~/project [⎇ main] [#123]                   Session: 8.33 AIC used

      \(frame) Working\(byteCount) esc interrupt          gpt-5.1
      """
    #expect(DetectedAgent.copilot.detectState(in: screen) == .working)
  }

  @Test func copilotWorkingCounterStillRequiresRuntimeChrome() {
    for screen in [
      "◉ Working · some prose esc interrupt",
      "Text: ◉ Working · 101 B esc interrupt",
      "● Working · 101 B esc interrupt",
      "◉ Working · 101 B esc interrupted",
      "◉ Working · 101 B esc interrupt\nResult\nOne\nTwo\nThree\nFour\nReady",
    ] {
      #expect(DetectedAgent.copilot.detectState(in: screen) == .idle)
    }
  }

  @Test func copilotSelectionFooterIsBlockedEvenWithWorkingTextAbove() {
    let screen = """
      ◉ Working · 101 B esc interrupt
      ╭──────────────────────────────────────╮
      │ Confirm folder trust                 │
      │ Do you trust the files in this folder?│
      │ ❯ 1. Yes                             │
      │   2. No (Esc)                        │
      │ ↑/↓ to navigate · enter to select · esc to cancel │
      ╰──────────────────────────────────────╯
      """
    #expect(DetectedAgent.copilot.detectState(in: screen) == .blocked)
  }

  @Test func copilotIgnoresQuotedAndStaleWorkingFooter() {
    for screen in [
      "The footer reads ◎ Working esc interrupt while processing.",
      "◎ Working esc interrupt\nResult\nOne\nTwo\nThree\nFour\nReady",
      "Working on documentation about esc interrupt",
    ] {
      #expect(DetectedAgent.copilot.detectState(in: screen) == .idle)
    }
  }
}
