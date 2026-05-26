import Testing

@testable import supacode

@MainActor
struct TerminalInputContextClassifierTests {
  @Test func codexProcessIsChatAgent() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "codex", argv0: "codex", cmdline: "codex")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "") == .chatAgent)
  }

  @Test func shellProcessIsCommandLike() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "zsh", argv0: "zsh", cmdline: "-zsh")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "") == .commandLike)
  }

  @Test func lazygitProcessIsCommandLike() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "lazygit", argv0: "lazygit", cmdline: "lazygit")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "") == .commandLike)
  }

  @Test func shellProcessIgnoresViewportAgentSignature() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "zsh", argv0: "zsh", cmdline: "-zsh")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "example approve") == .commandLike)
  }

  @Test func lazygitProcessIgnoresViewportAgentSignature() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "lazygit", argv0: "lazygit", cmdline: "lazygit")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "example approve") == .commandLike)
  }

  @Test func tmuxWithCodexViewportIsChatAgent() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "tmux", argv0: "tmux", cmdline: "tmux")
      ]
    )
    let viewport = "Codex\nReady for input\n/approvals"

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: viewport) == .chatAgent)
  }

  @Test func tmuxWithoutAgentSignatureIsCommandLike() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "tmux", argv0: "tmux", cmdline: "tmux")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "$ git status") == .commandLike)
  }

  @Test func tmuxCommandLineAgentTokenWithoutViewportSignatureIsCommandLike() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "tmux", argv0: "tmux", cmdline: "tmux new -s codex")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "$ git status") == .commandLike)
  }

  @Test func tmuxJobWithDirectAgentProcessIsChatAgent() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "tmux", argv0: "tmux", cmdline: "tmux"),
        ForegroundProcess(pid: 102, name: "codex", argv0: "codex", cmdline: "codex"),
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "$ git status") == .chatAgent)
  }

  @Test func tmuxJobWithWrappedAgentProcessIsChatAgent() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "tmux", argv0: "tmux", cmdline: "tmux"),
        ForegroundProcess(pid: 102, name: "node", argv0: "node", cmdline: "node /usr/local/bin/claude"),
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "$ git status") == .chatAgent)
  }

  @Test func tmuxViewportDoesNotMatchAgentSignatureInsideWords() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, name: "tmux", argv0: "tmux", cmdline: "tmux")
      ]
    )

    #expect(TerminalInputContextClassifier.context(job: job, viewportText: "example approve") == .commandLike)
  }

  @Test func missingJobDefaultsToCommandLike() {
    #expect(TerminalInputContextClassifier.context(job: nil, viewportText: "") == .commandLike)
  }
}
