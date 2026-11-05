import Foundation
import Testing

@testable import Prowl

struct MirrorScreenPromptTests {
  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures")

  private static func screen(_ path: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: path), encoding: .utf8)
  }

  @Test func claudeQuestionGivesItsOptionsAndMarksFreeformRows() throws {
    let prompt = try #require(
      MirrorScreenPrompt.parse(Self.screen("MirrorScreenPrompt/claude-2.1.318-ask-user-question.txt")))
    #expect(prompt.title == "Which image format do you prefer for icons?")
    #expect(prompt.options.map(\.label) == ["PNG", "WebP", "SVG", "Type something.", "Chat about this"])
    #expect(prompt.answers.map(\.number) == [1, 2, 3])
    #expect(prompt.options[1].detail == "Raster, smaller files, modern support.")
    #expect(prompt.selected == 1)
    #expect(!prompt.isPermission)
  }

  @Test func claudePermissionQuotesTheCommand() throws {
    let prompt = try #require(
      MirrorScreenPrompt.parse(Self.screen("MirrorScreenPrompt/claude-2.1.318-command-permission.txt")))
    #expect(prompt.title == "Do you want to proceed?")
    #expect(prompt.isPermission)
    #expect(prompt.options.first?.label == "Yes")
    #expect(prompt.options.last?.label == "No")
    #expect(prompt.detail?.hasPrefix("prowl agents dispatch-complete") == true)
  }

  @Test func codexApprovalReadsTheQuestionAboveTheCommand() throws {
    let prompt = try #require(
      MirrorScreenPrompt.parse(Self.screen("AgentScreenDetection/codex/0.146.1/blocked/command-permission.txt")))
    #expect(prompt.options.count == 3)
    #expect(prompt.options[0].label == "Yes, proceed (y)")
    #expect(prompt.detail == "touch permission-probe.txt")
    #expect(prompt.title.contains("Do you want to allow"))
    #expect(prompt.isPermission)
  }

  /// A Codex command over several lines stays the detail, under its real question (089 review
  /// S4-R5).
  @Test func codexMultilineCommandIsTheDetail() throws {
    let text = try Self.screen("AgentScreenDetection/codex/0.146.1/blocked/command-permission.txt")
    let loop = text.replacingOccurrences(
      of: "  $ touch permission-probe.txt",
      with: "  $ for f in a b; do\n      touch \"$f\"\n    done")
    let prompt = try #require(MirrorScreenPrompt.parse(loop))
    #expect(prompt.title.contains("Do you want to allow"))
    #expect(prompt.isPermission)
    #expect(prompt.detail == "for f in a b; do\ntouch \"$f\"\ndone")
    let other = try #require(MirrorScreenPrompt.parse(loop.replacingOccurrences(of: "touch \"$f\"", with: "rm \"$f\"")))
    #expect(other.id != prompt.id)
  }

  @Test func theIdentityIgnoresTheSelectionButNotTheOptions() throws {
    let text = try Self.screen("MirrorScreenPrompt/claude-2.1.318-ask-user-question.txt")
    let moved = text.replacingOccurrences(of: "❯ 1. PNG", with: "  1. PNG")
      .replacingOccurrences(of: "  2. WebP", with: "❯ 2. WebP")
    let first = try #require(MirrorScreenPrompt.parse(text))
    let second = try #require(MirrorScreenPrompt.parse(moved))
    #expect(second.selected == 2)
    #expect(first.id == second.id)
    let other = try #require(MirrorScreenPrompt.parse(moved.replacingOccurrences(of: "SVG", with: "AVIF")))
    #expect(other.id != first.id)
  }

  /// Two permissions with the same question and choices but different commands are different
  /// prompts (089 review S4-R1).
  @Test func theIdentityCoversTheCommandAndTheDescriptions() throws {
    let permission = try Self.screen("MirrorScreenPrompt/claude-2.1.318-command-permission.txt")
    let first = try #require(MirrorScreenPrompt.parse(permission))
    let other = try #require(
      MirrorScreenPrompt.parse(permission.replacingOccurrences(of: "--outcome succeeded", with: "--outcome failed")))
    #expect(first.detail != other.detail)
    #expect(first.id != other.id)
    let question = try Self.screen("MirrorScreenPrompt/claude-2.1.318-ask-user-question.txt")
    let described = try #require(MirrorScreenPrompt.parse(question))
    let redescribed = try #require(
      MirrorScreenPrompt.parse(question.replacingOccurrences(of: "Raster, smaller files", with: "Raster, larger files"))
    )
    #expect(described.id != redescribed.id)
  }

  @Test func theKeyGuardAllowsItsOwnKeysButNotLocalEditing() {
    var guardrail = MirrorKeyGuard(hasMarkedText: false, lastEditingAt: 10, now: 100)
    #expect(guardrail.refusal == nil)
    // The operation's own key moves the editing stamp; that is not a competing edit.
    guardrail.noteSent(lastEditingAt: 101)
    #expect(guardrail.check(hasMarkedText: false, lastEditingAt: 101) == nil)
    // Someone typed on the Mac after the last key went.
    #expect(guardrail.check(hasMarkedText: false, lastEditingAt: 102) != nil)
    #expect(guardrail.check(hasMarkedText: true, lastEditingAt: 101) != nil)
    // Recent local editing before the first key refuses at once.
    #expect(MirrorKeyGuard(hasMarkedText: false, lastEditingAt: 99.5, now: 100).refusal != nil)
  }

  @Test func numberedProseAndBrokenMenusAreNotPrompts() {
    #expect(MirrorScreenPrompt.parse("Plan:\n1. First\n2. Second\n\n> ") == nil)
    // A footer but no highlighted row.
    #expect(MirrorScreenPrompt.parse("Pick one\n  1. A\n  2. B\nEnter to select · Esc to cancel") == nil)
    // Numbers that skip.
    #expect(MirrorScreenPrompt.parse("Pick one\n❯ 1. A\n  3. B\nEnter to select · Esc to cancel") == nil)
  }

  @Test func navigationMovesOneRowAtATimeTowardTheAnswer() {
    #expect(MirrorScreenPrompt.nextKey(selected: 1, target: 3) == "down")
    #expect(MirrorScreenPrompt.nextKey(selected: 4, target: 2) == "up")
    #expect(MirrorScreenPrompt.nextKey(selected: 2, target: 2) == "enter")
  }
}
