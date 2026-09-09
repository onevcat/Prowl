import Foundation
import Testing

@testable import supacode

struct MirrorHistoryPageGateTests {
  private let id = UUID()

  private func page(offset: Int, total: Int = 3, lines: [String]) -> MirrorMessage {
    MirrorMessage(
      version: 2, kind: .historyPage, historyID: id, offset: offset,
      lines: lines, total: total, capturedAt: 1)
  }

  @Test func pagesMustContinueTheSameSnapshotAndStopAtZero() {
    var gate = MirrorHistoryPageGate()
    let first = gate.accept(page(offset: 1, lines: ["middle", "latest"]), requiresTimestamp: true)
    #expect(first)
    var changedID = page(offset: 0, lines: ["oldest"])
    changedID.historyID = UUID()
    var changedTime = page(offset: 0, lines: ["oldest"])
    changedTime.capturedAt = 2
    let invalid = [
      page(offset: 1, lines: ["middle", "latest"]),
      page(offset: 0, total: 4, lines: ["oldest"]),
      page(offset: 0, lines: []), changedID, changedTime,
    ]
    for message in invalid {
      let accepted = gate.accept(message, requiresTimestamp: true)
      #expect(!accepted)
    }
    let last = gate.accept(page(offset: 0, lines: ["oldest"]), requiresTimestamp: true)
    #expect(last)
    let extra = gate.accept(page(offset: 0, lines: []), requiresTimestamp: true)
    #expect(!extra)
  }

  @Test func cumulativeUTF8BytesShareOneBudget() {
    var gate = MirrorHistoryPageGate()
    let nearLimit = String(repeating: "a", count: MirrorHistory.maximumBytes - 3)
    let first = gate.accept(page(offset: 1, total: 2, lines: [nearLimit]), requiresTimestamp: true)
    #expect(first)
    let exceeded = gate.accept(page(offset: 0, total: 2, lines: ["🌍"]), requiresTimestamp: true)
    #expect(!exceeded)
    let fits = gate.accept(page(offset: 0, total: 2, lines: ["a"]), requiresTimestamp: true)
    #expect(fits)
  }

  @Test func legacyTimestampIsOptionalButModernTimestampMustBeFinite() {
    var legacy = MirrorHistoryPageGate()
    var message = page(offset: 0, total: 0, lines: [])
    message.capturedAt = nil
    let accepted = legacy.accept(message, requiresTimestamp: false)
    #expect(accepted)
    var modern = MirrorHistoryPageGate()
    for timestamp: TimeInterval? in [nil, .infinity, .nan] {
      message.capturedAt = timestamp
      let accepted = modern.accept(message, requiresTimestamp: true)
      #expect(!accepted)
    }
    message.capturedAt = 1
    let valid = modern.accept(message, requiresTimestamp: true)
    #expect(valid)
  }
}
