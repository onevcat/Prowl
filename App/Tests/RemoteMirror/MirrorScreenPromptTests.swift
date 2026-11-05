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
