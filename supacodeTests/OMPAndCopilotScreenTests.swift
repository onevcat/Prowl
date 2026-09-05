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

  @Test func copilotSelectionFooterIsBlockedEvenWithWorkingTextAbove() {
    let screen = """
      ◎ Working esc interrupt
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
