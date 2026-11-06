import Foundation
import Testing

@testable import Prowl

struct MirrorShellPromptTests {
  private struct Member {
    let pid: pid_t
    let name: String
    let arguments: [String]?
    init(_ pid: pid_t, _ name: String, _ arguments: [String]?) {
      self.pid = pid
      self.name = name
      self.arguments = arguments
    }
  }

  private static func job(_ members: [Member], group: pid_t = 100) -> ForegroundJob {
    ForegroundJob(
      processGroupID: group,
      processes: members.map {
        ForegroundProcess(
          pid: $0.pid, name: $0.name, argv0: $0.arguments?.first, cmdline: $0.arguments?.joined(separator: " "),
          arguments: $0.arguments)
      })
  }

  @Test func interactiveShellsAreAtTheirPrompt() {
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(100, "zsh", ["-zsh"])])) == nil)
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(100, "bash", ["/bin/bash", "--login", "-i"])])) == nil)
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(100, "fish", ["fish"])])) == nil)
  }

  @Test func programsInFrontOfTheShellRefuse() {
    let vim = MirrorShellPrompt.refusal(for: Self.job([Member(100, "vim", ["vim", "README.md"])]))
    #expect(vim?.contains("vim") == true)
    // A pipeline: two processes in the foreground group.
    #expect(
      MirrorShellPrompt.refusal(
        for: Self.job([Member(100, "tail", ["tail", "-f", "log"]), Member(101, "grep", ["grep", "x"])]))
        != nil)
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(100, "ssh", ["ssh", "mini"])])) != nil)
  }

  @Test func scriptsAndCommandStringsRefuse() {
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(100, "bash", ["bash", "build.sh"])])) != nil)
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(100, "zsh", ["zsh", "-c", "sleep 10"])])) != nil)
  }

  @Test func unreadableJobsRefuse() {
    #expect(MirrorShellPrompt.refusal(for: nil) != nil)
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(100, "zsh", nil)])) != nil)
    // The group leader is gone; only another member is left.
    #expect(MirrorShellPrompt.refusal(for: Self.job([Member(101, "zsh", ["-zsh"])])) != nil)
  }

  private static let zsh = job([Member(100, "zsh", ["-zsh"])])
  private static let primary = MirrorShellPrompt.InputState(primaryPrompt: true, bracketedPaste: true)

  /// 089 review R1/R2: the process inventory is the same at a continuation prompt and while a
  /// builtin `read` waits; only the terminal's primary-prompt evidence lets a command go.
  @Test func onlyAPrimaryPromptTakesACommand() {
    #expect(MirrorShellPrompt.refusal(for: Self.zsh, input: Self.primary, text: "ls") == nil)
    let pending = MirrorShellPrompt.InputState(primaryPrompt: false, bracketedPaste: true)
    #expect(MirrorShellPrompt.refusal(for: Self.zsh, input: pending, text: "ls") != nil)
    #expect(MirrorShellPrompt.refusal(for: Self.zsh, input: nil, text: "ls") != nil)
    // A program in front is named, even at what looks like a prompt.
    let vim = Self.job([Member(100, "vim", ["vim"])])
    #expect(MirrorShellPrompt.refusal(for: vim, input: Self.primary, text: "ls")?.contains("vim") == true)
  }

  /// 089 review R3: without bracketed paste, a newline would run its line and a tab would complete.
  @Test func linesAndTabsNeedBracketedPaste() {
    let plain = MirrorShellPrompt.InputState(primaryPrompt: true, bracketedPaste: false)
    for text in ["echo a\necho b", "printf '%s' A\tB", "echo a\r"] {
      #expect(MirrorShellPrompt.needsPaste(text))
      #expect(MirrorShellPrompt.refusal(for: Self.zsh, input: plain, text: text) != nil)
      #expect(MirrorShellPrompt.refusal(for: Self.zsh, input: Self.primary, text: text) == nil)
    }
    #expect(MirrorShellPrompt.refusal(for: Self.zsh, input: plain, text: "echo one line") == nil)
  }
}
