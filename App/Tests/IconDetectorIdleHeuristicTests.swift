import Testing

@testable import supacode

/// Pure-shape detection of the shell's idle prompt
/// (`isLikelyIdleTitleByShape`). The bootstrap filter that runs
/// before the per-surface learner has memorised the prompt at least
/// once.
struct IconDetectorIdleHeuristicTests {
  // MARK: - Idle prompt shapes

  @Test func detectsUserAtHostWithColonPath() {
    #expect(WorktreeTerminalState.isLikelyIdleTitleByShape("onevcat@Mac:~/Sync/github/YiTong"))
  }

  @Test func detectsUserAtHostWithSlashOnly() {
    #expect(WorktreeTerminalState.isLikelyIdleTitleByShape("onevcat@Mac:/usr/local/etc"))
  }

  @Test func detectsTildePath() {
    #expect(WorktreeTerminalState.isLikelyIdleTitleByShape("~/Sync/github"))
  }

  @Test func detectsAbsolutePath() {
    #expect(WorktreeTerminalState.isLikelyIdleTitleByShape("/usr/local/bin"))
  }

  @Test func detectsTruncatedPathWithEllipsis() {
    // zsh's "compact path" renders as `…/Sync/github/YiTong`.
    #expect(WorktreeTerminalState.isLikelyIdleTitleByShape("…/Sync/github/YiTong"))
  }

  // MARK: - Real commands should not be flagged

  @Test func commandWithSpaceIsNotIdle() {
    // Anything with a space is treated as a real command (program +
    // args) — this is the primary discriminator.
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("git status"))
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("vim file.swift"))
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("docker compose up"))
  }

  @Test func barCommandTokenIsNotIdle() {
    // Single-token commands without `@`, `~`, `/`, or `…` are real
    // commands.
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("claude"))
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("vim"))
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("npm"))
  }

  @Test func tuiTitleIsNotIdle() {
    // TUI tools that rewrite their own title (claude → spinner glyphs)
    // contain spaces and should still be classified as commands.
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("✳ Claude Code"))
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("⠐ Claude Code"))
  }

  @Test func emptyTitleIsNotIdle() {
    // Empty handled by the caller; the heuristic itself returns false
    // (no `@`, no leading `~`/`/`/`…`).
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape(""))
  }

  // MARK: - Edge cases

  @Test func atSymbolWithoutPathSeparatorIsNotIdle() {
    // `git@github.com` would be a typical SSH remote, not an idle
    // prompt. Without `:` or `/` it's not classified as idle.
    #expect(!WorktreeTerminalState.isLikelyIdleTitleByShape("git@github.com"))
  }

  @Test func absolutePathExecutableIsClassifiedAsIdle() {
    // Documented limitation: `/usr/bin/python3` (rare invocation
    // form) shape-matches as a "path" prompt and gets skipped. The
    // tradeoff is fine — typical use is `python3`, not the absolute
    // path.
    #expect(WorktreeTerminalState.isLikelyIdleTitleByShape("/usr/bin/python3"))
  }
}
