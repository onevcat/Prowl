import Testing

@testable import supacode

/// Reconstructed screens for the background-agent lifecycle.
///
/// The captured evidence lives in the fixture corpus; these are the synthetic
/// boundary cases around it, kept inline per the corpus README.
struct ClaudeBackgroundAgentDetectionTests {
  private func detect(_ screen: String) -> AgentScreenDetection {
    DetectedAgent.claude.detectScreen(in: screen)
  }

  @Test func waitRowReportsWorkingWithoutASpinnerEllipsis() {
    // Claude Code 2.1.224. The turn has ended, so the only live marker is the wait
    // row. It carries a spinner glyph but no "…", which hasSpinnerActivity requires.
    let detection = detect(
      """
      ⏺ Subagent launched in the background, running sleep 300.

      ✻ Waiting for 1 background agent to finish
      ─────────
      ❯
      ─────────
        ⏵⏵ auto mode on · 1 shell

        ⏺ main
        ◯ general-purpose  Sleep 300 then reply    1m 5s · ↓ 21.4k tokens
      """
    )

    #expect(detection.state == .working)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.backgroundWork))
  }

  @Test func retainedAgentRowAloneDoesNotReportWorking() {
    // Claude Code 2.1.224, observed live. A subagent that returned control but is
    // still awaiting collection keeps its switcher row, with the elapsed value
    // frozen at the moment it stopped. Nothing is running, so the pane must not
    // report working — matching the "◯" row shape alone would pin it there.
    let detection = detect(
      """
      ⏺ Agent "Sleep 300 then reply" finished · 1m 54s

        Ran 3 shell commands

      ✻ Churned for 2m 49s · 2 shells still running
      ─────────
      ❯
      ─────────
        ⏵⏵ auto mode on · 2 shells

        ⏺ main
        ◯ general-purpose  Sleep 300 then reply    1m 54s · ↓ 23.0k tokens
      """
    )

    #expect(detection.state == .idle)
  }

  @Test func waitRowQuotedEarlierInTheTranscriptDoesNotReportWorking() {
    // The rule reads the live status region, which is the last three non-blank
    // lines above the prompt box. A wait row quoted further back in the
    // transcript falls outside that window and stays idle.
    //
    // A quote inside the window is indistinguishable from live chrome on a single
    // screen and does report working; the same limit applies to every rule scoped
    // this way, including the pre-existing spinner rule.
    let detection = detect(
      """
      ⏺ Earlier the screen showed:

        ✻ Waiting for 1 background agent to finish

      ⏺ That row is the one the detector keys on.
      ⏺ It is quoted here, four lines above the box.
      ⏺ Nothing is running now.
      ─────────
      ❯
      ─────────
        ⏵⏵ auto mode on (shift+tab to cycle)
      """
    )

    #expect(detection.state == .idle)
  }

  @Test func workflowFooterVariantStillReportsWorking() {
    // The pre-existing "agents done" workflow row keeps its behaviour and reason.
    let detection = detect(
      """
      Task complete.
      ─────────
      ❯
      ─────────
      ◯ scout  Map idle detection  3/5 agents done · 7m 29s
      """
    )

    #expect(detection.state == .working)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.backgroundWork))
  }

  @Test func elapsedStatusAcceptsMultiWordLabelsAndCompoundElapsed() {
    let working = [
      "● Running gates and merge lifecycle… (45s · ↓ 13.2k tokens)",
      "● Actioning… (28m 34s · ↓ 47.7k tokens)",
      "● Actioning… (1h 4m 2s · ↓ 47.7k tokens)",
      "● Perusing… (3s · ↓ 77 tokens)",
    ]
    for row in working {
      let detection = detect(
        """
        \(row)
        ─────────
        ❯
        ─────────
        """
      )
      #expect(detection.state == .working, "expected working for: \(row)")
      #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.elapsedStatus))
    }
  }

  @Test func wrappedRowsAreReadAsOneLogicalRow() {
    // Claude Code 2.1.225 at 40 columns. Both shapes were observed on a real
    // narrow pane; the continuation is indented two spaces.
    let wrappedWait = detect(
      """
      ⏺ The subagent is running; waiting for its reply.

      ✻ Waiting for 1 background agent to
        finish
      ────────
      ❯
      ────────
      """
    )
    #expect(wrappedWait.state == .working)
    #expect(wrappedWait.reason == .matched(ClaudeScreenProfile.RuleID.backgroundWork))

    let wrappedElapsed = detect(
      """
      ● Running gates and merge lifecycle…
        (1m 38s · ↓ 187 tokens)
      ────────
      ❯
      ────────
      """
    )
    #expect(wrappedElapsed.state == .working)
    #expect(wrappedElapsed.reason == .matched(ClaudeScreenProfile.RuleID.elapsedStatus))
  }

  @Test func rowWrappedPastTheRegionLimitKeepsItsHead() {
    // The live status region is the last three rows above the box. A row narrow
    // enough to wrap onto four or more physical lines pushes its own head out of
    // a window counted in physical lines, and the head carries the glyph every
    // rule keys on. The region is therefore reconstructed into logical rows
    // before the limit applies.
    let wrappedWait = detect(
      """
      ⏺ Launched it.

      ✻ Waiting
        for 1
        background
        agent to
        finish
      ────
      ❯
      ────
      """
    )
    #expect(wrappedWait.state == .working)
    #expect(wrappedWait.reason == .matched(ClaudeScreenProfile.RuleID.backgroundWork))

    let wrappedElapsed = detect(
      """
      ⏺ Started.

      ● Running
        gates…
        (1m 38s ·
        ↓ 187
        tokens)
      ────
      ❯
      ────
      """
    )
    #expect(wrappedElapsed.state == .working)
    #expect(wrappedElapsed.reason == .matched(ClaudeScreenProfile.RuleID.elapsedStatus))
  }

  @Test func continuationJoiningDoesNotInventRows() {
    // A following line that carries its own marker starts a new row rather than
    // continuing the previous one, so nothing is stitched into a status row that
    // was never on screen.
    let detection = detect(
      """
      ⏺ Wrote the report.
        ⎿  Waiting for 1 background agent to finish is what it said earlier
      ⏺ Nothing is running now.
      ────────
      ❯
      ────────
      """
    )

    #expect(detection.state == .idle)
  }

  @Test func labelContainingParenthesesStillParses() {
    // The label is free text, so the elapsed segment is located from the end of
    // the row. Anchoring at the first "(" reads "focused)… (1m 38s" as elapsed.
    let detection = detect(
      """
      ● Running tests (focused)… (1m 38s · ↓ 187 tokens)
      ────────
      ❯
      ────────
      """
    )

    #expect(detection.state == .working)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.elapsedStatus))
  }

  @Test func narrowPaneDropsDetailSegmentsAndStillParses() {
    // At 32 columns Claude shortens the row rather than wrapping it, leaving the
    // elapsed terminated by the closing paren with no " · " detail at all.
    let detection = detect(
      """
      ● Razzle-dazzling… (1m 7s)
      ────────
      ❯
      ────────
      """
    )

    #expect(detection.state == .working)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.elapsedStatus))
  }

  @Test func incompleteElapsedSegmentsStayIdle() {
    let notWorking = [
      "● Retrying the merge lifecycle… (1st attempt)",
      "● Actioning… (10seconds · ↓ 47.7k tokens)",
      "● Actioning… (28m 34 · ↓ 47.7k tokens)",
      // Incomplete elapsed carried across a wrapped row stays incomplete.
      "● Running gates and merge lifecycle…\n  (1st attempt)",
      "● Running tests (focused)…\n  (10seconds · ↓ 187 tokens)",
    ]
    for row in notWorking {
      let detection = detect(
        """
        \(row)
        ─────────
        ❯
        ─────────
        """
      )
      #expect(detection.state == .idle, "expected idle for: \(row)")
    }
  }
}
