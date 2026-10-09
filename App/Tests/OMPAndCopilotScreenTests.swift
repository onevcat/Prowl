import Testing

@testable import Prowl

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

  // OMP 18.8: the loader label is the model's self-reported intent, so the Esc glyph
  // is the cue, not the `Working…` text. Captured from omp 18.8.6 with a static brand
  // glyph in the composer header so only the loader row carries the evidence.
  @Test(arguments: ["󱊷", "⎋", "esc"], ["Running requested command", "Waiting then confirming", "等待命令完成"])
  func ompRecognizesIntentLoaderRow(prefix: String, intent: String) {
    let screen = """
      ╭──────────────────────────────╮
      │ $ sleep 150 && echo finished │
      ╰──────────────────────────────╯

       2026-10-09 20:35:15   243   100   7.8K   1.5s   43.4/s

        \(prefix) \(intent)

      ╭── 󰵗   GPT-5.6 Sol · 󰪡 med   ~/project   master  󰙺 0.04 ────3%──────╮
      ╰─                                                                   ─╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .working)
    #expect(DetectedAgent.pi.detectState(in: screen) == .idle)
  }

  @Test func ompDoesNotTreatQuotedOrStaleEscapeHintAsWorking() {
    for screen in [
      "The status says 󱊷 Working… while processing.",
      "󱊷 Working…\nResult\nOne\nTwo\nThree\nFour\nReady",
      "󱊷 Running requested command\nResult\nOne\nTwo\nThree\nFour\nReady",
      "escape Working…",
      "󱊷 ⠋ 42",
      "󱊷",
    ] {
      #expect(DetectedAgent.omp.detectState(in: screen) == .idle)
    }
  }

  @Test(arguments: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
  func ompRecognizesComposerSpinner(frame: String) {
    let screen = """
      󱊷 Running a tool
      ╭── \(frame) 2m · model · ~/project ──╮
      ╰─                                  ─╯
      Extension status
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .working)
    #expect(DetectedAgent.pi.detectState(in: screen) == .idle)
  }

  // omp 18.8.6 `box` composer during a bash tool call: the brand spinner and turn timer
  // sit in the top border. The loader row is left out so the header alone decides.
  @Test(arguments: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
  func ompRecognizesBoxComposerHeaderSpinner(frame: String) {
    let screen = """
      ╭──────────────────────────────╮
      │ $ sleep 150 && echo finished │
      ╰──────────────────────────────╯

       2026-10-09 20:35:15   243   100   7.8K   1.5s   43.4/s

      ╭── \(frame) 32s   GPT-5.6 Sol · 󰪡 med   ~/project   master  󰙺 0.04 ────3%────╮
      ╰─                                                                     ─╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .working)
    #expect(DetectedAgent.pi.detectState(in: screen) == .idle)
  }

  // A queued draft adds `│` input rows between the header and the bottom row.
  @Test func ompRecognizesBoxComposerSpinnerWithMultilineDraft() {
    let screen = """
      ╭──────────────────────────────╮
      │ $ sleep 60 && echo finished  │
      ╰──────────────────────────────╯

       2026-10-09 20:43:17   234   100   8.2K   1.7s   38.7/s

      ╭── ⠋ 19s   GPT-5.6 Sol · 󰪡 med   ~/project   master  󰙺 0.06 ────3%────╮
      │  draft line one, please ignore                                        │
      ╰─ draft line two, reply with ok                                       ─╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .working)
  }

  // `tui.imeSafeCursor` moves the bottom border to its own row below a `│` input row.
  @Test func ompRecognizesImeSafeBoxComposerSpinner() {
    let screen = """
       2026-10-09 20:44:55   8K   100   2.2s   32.3/s

      ╭── ⠇ 19s   GPT-5.6-Sol · 󰪡 med   ~/project   master  󰙺 0.03 ────3%────╮
      │
      ╰───────────────────────────────────────────────────────────────────────╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .working)
  }

  // The composer grows with the draft (up to 18 rows), so the loader row above it must
  // stay evidence even when it leaves the bottom five rows.
  @Test func ompRecognizesLoaderRowAboveLongDraft() {
    let draftRows = (1...8).map { "│  queued line \($0)" }.joined(separator: "\n")
    let screen = """
      Earlier answer text.

        󱊷 Working…

      ╭── 󰵗   GPT-5.6 Sol · 󰪡 med   ~/project   master  󰙺 ────3%──────╮
      \(draftRows)
      ╰─ queued line 9                                                 ─╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .working)
  }

  // The `band` (fresh-install default) and `claude` composer shapes start a status row
  // with the brand spinner, which the leading-spinner rule reads; captured from omp 18.8.6.
  @Test func ompRecognizesSpinnerStatusRowsOfOtherComposerShapes() {
    let band = """
      ╭──────────────────────────────╮
      │ $ sleep 45 && echo finished  │
      ╰──────────────────────────────╯

       2026-10-09 20:45:58   8.1K   54   2.0s   20.6/s

       ⠏ 19s   GPT-5.6-Sol · 󰪡 med   ~/project   master  󰙺 0.03 ─────3%───────
      ╰─
      """
    let claude = """
       2026-10-09 20:47:42   946   100   7.2K   1.5s   35.4/s

      ──────────────────────────────────────────────────────────────────────────
      ❯
      ──────────────────────────────────────────────────────────────────────────
       ⠙ 15s ·  GPT-5.6-Sol · 󰪡 med ·  ~/project ·  master ·  3.0%/272K 󰁨 · 󰙺 0.01
      """
    #expect(DetectedAgent.omp.detectState(in: band) == .working)
    #expect(DetectedAgent.omp.detectState(in: claude) == .working)
  }

  // Idle composers of every captured shape after a completed turn.
  @Test func ompIdleComposersStayIdle() {
    let box = """
       done

       2026-10-09 20:37:48   320   5   8.1K   1.2s   3.7/s

      ╭── 󰵗   GPT-5.6 Sol · 󰪡 med   ~/project   master  󰙺 0.05 ────3%─────────╮
      ╰─                                                                     ─╯
      """
    let imeSafeBox = """
       done

      ╭── 󰵗   GPT-5.6-Sol · 󰪡 med   ~/project   master  󰙺 ─────3%───────────╮
      │
      ╰───────────────────────────────────────────────────────────────────────╯
      """
    let band = """
       done

       󰵗   GPT-5.6-Sol · 󰪡 med   ~/project   master  󰙺 ─────3%──────────
      ╰─
      """
    let claude = """
       done

      ──────────────────────────────────────────────────────────────────────────
      ❯
      ──────────────────────────────────────────────────────────────────────────
       󰵗 ·  GPT-5.6-Sol · 󰪡 med ·  ~/project ·  master ·  3.0%/272K 󰁨 · 󰙺
      """
    for screen in [box, imeSafeBox, band, claude] {
      #expect(DetectedAgent.omp.detectState(in: screen) == .idle)
    }
  }

  @Test func ompComposerSpinnerRequiresLiveComposerStructure() {
    for screen in [
      "╭── 󰵗 · model · ~/project ──╮\n╰─ ─╯\nExtension status",
      "The footer reads ╭── ⠧ 2m · model ──╮\n╰─ ─╯",
      "╭── ⠧ 2m · model ──╮\nResult",
      "╭── ⠧ 2m · model ──╮\n╰─ ─╯\nResult\nOne\nTwo\nThree\nReady",
      "╭── ⠧ 2m · model ──╮\n│ draft\nNot a composer row\n╰─ ─╯",
    ] {
      #expect(DetectedAgent.omp.detectState(in: screen) == .idle)
    }
  }

  // A quoted spinner frame in the answer does not speak for the newer idle composer below.
  @Test func ompIgnoresHistoricalSpinnerBoxAboveIdleComposer() {
    let screen = """
      The footer looked like this while the tool ran:

      ╭── ⠧ 2m · model · ~/project ──╮
      ╰─                            ─╯

      ╭── 󰵗   GPT-5.6 Sol · 󰪡 med   ~/project   master  󰙺 0.05 ────3%──────╮
      ╰─                                                                  ─╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .idle)
  }

  @Test func ompAskPromptTakesPrecedenceOverComposerSpinner() {
    let screen = """
      Enter select · Esc cancel
      ╭── ⠧ 2m · model ──╮
      ╰─                  ─╯
      """
    #expect(DetectedAgent.omp.detectState(in: screen) == .blocked)
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
