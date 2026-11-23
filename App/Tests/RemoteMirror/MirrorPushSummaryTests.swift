import Foundation
import Testing

@testable import Prowl

struct MirrorPushSummaryTests {
  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures")
  private static let conversation = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Mirror/Fixtures/conversation")

  private static func screen(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: "MirrorScreenPrompt/\(name)"), encoding: .utf8)
  }

  @Test func aBlockedAgentShowsItsQuestionAndWhatItIsAbout() throws {
    #expect(
      MirrorPushSummary.question(onScreen: try Self.screen("claude-2.1.322-folder-trust.txt"))
        == "Trust this folder? · /private/tmp/pm-e2e/Trust3")
    let permission = try #require(
      MirrorPushSummary.question(onScreen: try Self.screen("claude-2.1.318-command-permission.txt")))
    #expect(permission.hasPrefix("Do you want to proceed? · prowl agents dispatch-complete"))
    #expect(MirrorPushSummary.question(onScreen: "$ ls\nREADME.md\n$ ") == nil)
  }

  @Test func aFinishedAgentShowsTheStartOfItsLastReply() throws {
    let transcript = Self.conversation.appending(path: "claude-review-1038.jsonl")
    let reply = try #require(MirrorPushSummary.lastReply(transcript: transcript, agent: .claude))
    #expect(reply.hasPrefix("审查报告已经在上面了喵，dispatch 也以 succeeded 收尾。 一句话回顾："))
    #expect(reply.count <= MirrorPushSummary.maximumCharacters && reply.hasSuffix("…"))
    #expect(MirrorPushSummary.lastReply(transcript: URL(fileURLWithPath: "/nonexistent.jsonl"), agent: .claude) == nil)
  }

  @Test func aReplyBecomesOneShortLine() {
    #expect(
      MirrorPushSummary.oneLine("## Done\n\nFixed **two** bugs in `Foo.swift`.\n")
        == "Done Fixed two bugs in Foo.swift.")
    #expect(MirrorPushSummary.oneLine(" \n\t ") == nil)
    let long = MirrorPushSummary.oneLine(String(repeating: "word ", count: 100))
    #expect(long?.count == MirrorPushSummary.maximumCharacters && long?.hasSuffix("…") == true)
  }

  @Test func thePushCarriesTheSummaryUnlessItIsTooLarge() throws {
    let device = MirrorPairedDevice(id: UUID(), name: "Phone", key: Data(repeating: 7, count: 32), pairedAt: Date())
    let hostID = UUID()
    let push = MirrorPushPlanner.Push(deviceID: device.id, paneID: UUID(), kind: .blocked)
    let key = MirrorPushCrypto.key(deviceSecret: device.key, hostID: hostID)
    func body(_ summary: String?) throws -> String {
      let request = try #require(
        MirrorPushSender.request(
          for: push, device: device, hostID: hostID,
          details: .init(title: "Prowl · main", stateChangedAt: nil, summary: summary)))
      #expect(request.sealed.count <= MirrorPushContract.maximumSealedLength)
      return try MirrorPushContent.decode(MirrorPushCrypto.open(request.sealed, key: key)).body
    }
    #expect(try body("Trust this folder? · /tmp/x") == "Trust this folder? · /tmp/x")
    #expect(try body(nil) == "An agent needs your attention")
    // Only a summary built elsewhere could be this long; it still must not break the push.
    #expect(try body(String(repeating: "界", count: 2_000)) == "An agent needs your attention")
  }
}
