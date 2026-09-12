import Testing

@testable import supacode

struct ClaudeScreenProfileTests {
  @Test func composerContentsPreservesDraftsAndAttachments() {
    for draft in ["", "hello", "hello\n  second line", "[Image #1]", "[Pasted text #1 +20 lines]"] {
      let screen = AgentScreenSnapshot(text: "──────── Title ─\n❯ " + draft + "\n────────\nstatus")
      #expect(ClaudeScreenProfile.composerContents(in: screen) == draft)
    }
    #expect(ClaudeScreenProfile.composerContents(in: AgentScreenSnapshot(text: "❯ old transcript")) == nil)
    #expect(ClaudeScreenProfile.composerContents(in: AgentScreenSnapshot(text: "────\n❯ draft")) == nil)
  }

  @Test func ruleIDsAreUniqueAndRuntimePrefixed() {
    let ruleIDs = ClaudeScreenProfile.RuleID.all

    #expect(Set(ruleIDs).count == ruleIDs.count)
    #expect(ruleIDs.allSatisfy { $0.rawValue.hasPrefix("claude.") })
  }

  @Test func capturedFixturesHaveStableReasonsIncludingViewerFix() throws {
    let expectedReasons: [String: AgentScreenDetectionReason] = [
      "claude/2.1.223/blocked/command-permission.txt": .matched(
        ClaudeScreenProfile.RuleID.blockedPrompt
      ),
      "claude/2.1.223/blocked/workspace-trust.txt": .matched(
        ClaudeScreenProfile.RuleID.blockedPrompt
      ),
      "claude/2.1.223/idle/composer.txt": .matched(ClaudeScreenProfile.RuleID.idleComposer),
      "claude/2.1.223/idle/quoted-permission.txt": .matched(
        ClaudeScreenProfile.RuleID.idleComposer
      ),
      "claude/2.1.223/unknown/676-history-search-viewer.txt": .matched(
        ClaudeScreenProfile.RuleID.viewer
      ),
      "claude/2.1.223/working/backgrounded-subagent.txt": .matched(
        ClaudeScreenProfile.RuleID.spinner
      ),
      "claude/2.1.223/working/foreground-spinner.txt": .matched(
        ClaudeScreenProfile.RuleID.spinner
      ),
      "claude/2.1.223/working/subagent-active.txt": .matched(
        ClaudeScreenProfile.RuleID.spinner
      ),
      "claude/2.1.224/working/676-background-agent-wait.txt": .matched(
        ClaudeScreenProfile.RuleID.backgroundWork
      ),
      "claude/2.1.224/working/676-compound-elapsed-status.txt": .matched(
        ClaudeScreenProfile.RuleID.elapsedStatus
      ),
      "claude/2.1.226/working/676-wrapped-background-agent-wait.txt": .matched(
        ClaudeScreenProfile.RuleID.backgroundWork
      ),
      "claude/2.1.266/idle/titled-composer.txt": .matched(ClaudeScreenProfile.RuleID.idleComposer),
      "claude/2.1.266/working/titled-border-spinner.txt": .matched(
        ClaudeScreenProfile.RuleID.spinner
      ),
    ]
    let fixtures = try AgentScreenFixtureCorpus.load().filter { $0.agent == .claude }

    #expect(fixtures.count == expectedReasons.count)
    for fixture in fixtures {
      let detection = DetectedAgent.claude.detectScreen(in: fixture.text)
      #expect(detection.state == fixture.expectedState)
      #expect(detection.reason == expectedReasons[fixture.relativePath])
    }
  }

  @Test func titledComposerBorderStillFramesTheComposer() {
    let working = ClaudeScreenProfile.detect(
      in: AgentScreenSnapshot(
        text: """
            ✢ Crafting… (19s · still thinking with xhigh effort)
              ⎿  Tip: Use /permissions to pre-approve tools

            ──────────────────── Titled composer border probe ─
            ❯
            ───────────────────────────────────────────────────
          """
      )
    )
    #expect(working.state == .working)
    #expect(working.reason == .matched(ClaudeScreenProfile.RuleID.spinner))

    let idle = ClaudeScreenProfile.detect(
      in: AgentScreenSnapshot(
        text: """
            ⏺ Done.

            ──────────────────── Titled composer border probe ─
            ❯
            ───────────────────────────────────────────────────
          """
      )
    )
    #expect(idle.state == .idle)
    #expect(idle.reason == .matched(ClaudeScreenProfile.RuleID.idleComposer))

    // A chip without its closing rule character is prose, not a border.
    let unterminated = ClaudeScreenProfile.detect(
      in: AgentScreenSnapshot(
        text: """
            ✢ Crafting… (19s · still thinking with xhigh effort)
            ──────────────────── Titled composer border probe
            ❯
            ───────────────────────────────────────────────────
          """
      )
    )
    #expect(unterminated.reason == .noRuleMatched)
  }

  @Test func elapsedAndBackgroundWorkHaveDistinctReasons() {
    let elapsed = ClaudeScreenProfile.detect(
      in: AgentScreenSnapshot(
        text: """
            ● Forging… (10s · thinking with high effort)
            ─────────
            ❯
            ─────────
          """
      )
    )
    #expect(elapsed.state == .working)
    #expect(elapsed.reason == .matched(ClaudeScreenProfile.RuleID.elapsedStatus))

    let background = ClaudeScreenProfile.detect(
      in: AgentScreenSnapshot(
        text: """
            Task complete.
            ─────────
            ❯
            ─────────
            ◯ scout  Map idle detection  3/5 agents done · 7m 29s
          """
      )
    )
    #expect(background.state == .working)
    #expect(background.reason == .matched(ClaudeScreenProfile.RuleID.backgroundWork))
  }

  @Test func blockerOutranksRetainedSpinner() {
    let detection = ClaudeScreenProfile.detect(
      in: AgentScreenSnapshot(
        text: """
            ✻ Tempering… (12s · esc to interrupt)
            Do you want to proceed?
            ❯ 1. Yes
              2. No
            Esc to cancel · Tab to amend
          """
      )
    )

    #expect(detection.state == .blocked)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.blockedPrompt))
  }

  @Test func blockerTextPreservesClaudeQuestionChoicesAndKeyboardHints() throws {
    let fixture = try AgentScreenFixtureCorpus.load()
      .first { $0.relativePath == "claude/2.1.223/blocked/command-permission.txt" }
    let text = try #require(fixture).text

    let blocker = ClaudeScreenProfile.blockerText(in: AgentScreenSnapshot(text: text))

    #expect(blocker?.contains("Do you want to proceed?") == true)
    #expect(blocker?.contains("❯ 1. Yes") == true)
    #expect(blocker?.contains("3. No") == true)
    #expect(blocker?.contains("Esc to cancel · Tab to amend · ctrl+e to explain") == true)
  }

  @Test func spinnerAboveLongTodoListStaysWorking() {
    // Regression: a bottom-measured line budget (the shared recent-line tail)
    // let a long todo list plus the composer and a multi-line status line push
    // the live spinner row out of the detector window, so a working agent was
    // reported idle via the idle-composer rule. The todo block is sized from
    // the tail limit so this screen keeps overflowing it if the limit moves.
    var lines = [
      "✻ Implementing hybridTopK… (5m 5s · ↓ 21.1k tokens)",
      "  ⎿ \u{00A0}✔ Write failing tests for hybridTopK and per-scope pickCandidates",
    ]
    for index in 2...(agentDetectionRecentLineLimit + 2) {
      lines.append("     ◻ Todo item number \(index) still pending")
    }
    lines.append(
      contentsOf: [
        "──────────────────────────────────────────",
        "❯ ",
        "──────────────────────────────────────────",
        "  [Fable 5 | Enterprise] ██░░░░░░░░ 16% | will git:(master*)",
        "  ███░░░░░░░ 34% (4h 3m / 5h) | ███░░░░░░░ 29% (4d 19h / 7d)",
        "  ✓ Bash ×7 | ✓ Read ×6 | ✓ Edit ×5",
        "  ▸ Implement hybridTopK in similarity.ts (2/16)",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents",
      ]
    )
    let nonBlankCount = lines.count { $0.contains { !$0.isWhitespace } }
    #expect(nonBlankCount > agentDetectionRecentLineLimit)

    let detection = DetectedAgent.claude.detectScreen(in: lines.joined(separator: "\n"))

    #expect(detection.state == .working)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.spinner))
  }

  @Test func spinnerAboveQueuedMessagesAndTipStaysWorking() {
    // The live status block is bounded by row shape, not by a fixed row
    // count: a "⎿" tip attachment, queued "❯" messages, and the right-aligned
    // effort chrome all belong to the block and must not displace the spinner.
    let text = """
      ⏺ Running 1 shell command…
        ⎿  $ touch permission-probe.txt

      ✻ Slithering… (16s · ↓ 21.1k tokens)
        ⎿  Tip: Use ctrl+v to paste images from your clipboard

        ❯ Run the shell command `sleep 8`, then reply exactly DONE.
        ❯ Then summarize the diff in one line.
                                                        ◉ xhigh · /effort
      ──────────────────────────────────────────
      ❯ Press up to edit queued messages
      ──────────────────────────────────────────
      """

    let detection = DetectedAgent.claude.detectScreen(in: text)

    #expect(detection.state == .working)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.spinner))
  }

  @Test func spinnerAboveQueuedMessageWithBlankLineStaysWorking() {
    // Live capture: a queued "❯" message whose body contains a blank line
    // renders its trailing paragraph as an unmarked prose row. The bottom-up
    // shape scan must not end the live block there — the paragraph still
    // belongs to the queued block, and stopping demoted the spinner above it
    // to history, so a working agent read as idle.
    let text = """
      ⏺ Waiting for a new run to appear on the poc repo · 2m 35s
        ⎿  $ until gh api "repos/acme/poc/actions/runs" >/dev/null; do sleep 5; done (2m 35s)
           (ctrl+b to run in background)

      ✻ Combobulating… (14m 4s · ↓ 141.9k tokens)

        ❯ https://example.com/acme/poc/actions/runs/18352009

          这个是你发的么
        ❯ https://example.com/acme/poc/actions/runs/18352094
          还有这个

      ──────────────────────────────────────────
      ❯ Press up to edit queued messages
      ──────────────────────────────────────────
        ✓ Bash ×18 | ✓ Edit ×1
        ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
      """

    let detection = DetectedAgent.claude.detectScreen(in: text)

    #expect(detection.state == .working)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.spinner))
  }

  @Test func spinnerQuotedAboveTranscriptBlockStaysIdle() {
    // A status row quoted in the transcript sits above a "⏺" block head. The
    // live block scan stops at that head, so reading the full active screen
    // must not resurrect the quoted spinner as live activity.
    var lines = [
      "✻ Tempering… (12s · esc to interrupt)",
      "",
      "⏺ Here is the analysis:",
    ]
    lines.append(contentsOf: (1...20).map { "    analysis detail line \($0)" })
    lines.append(
      contentsOf: [
        "",
        "✻ Crunched for 7s",
        "",
        "──────────────────────────────────────────",
        "❯ ",
        "──────────────────────────────────────────",
        "  ⏸ manual mode on · ← for agents",
      ]
    )

    let detection = DetectedAgent.claude.detectScreen(in: lines.joined(separator: "\n"))

    #expect(detection.state == .idle)
    #expect(detection.reason == .matched(ClaudeScreenProfile.RuleID.idleComposer))
  }

  @Test func unstructuredScreenUsesExplicitFallback() {
    let detection = ClaudeScreenProfile.detect(
      in: AgentScreenSnapshot(text: "screen without live Claude chrome")
    )

    #expect(detection.state == .idle)
    #expect(detection.reason == .noRuleMatched)
  }
}
