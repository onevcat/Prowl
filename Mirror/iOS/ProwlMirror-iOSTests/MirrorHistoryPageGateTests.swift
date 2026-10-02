import Foundation
import Testing

@testable import ProwlMirror_iOS

struct MirrorHistoryPageGateTests {
  private let id = UUID()

  private func page(
    offset: Int, total: Int = 3, lines: [String], snapshotID: UUID? = nil,
    timestamp: TimeInterval = 1
  ) -> MirrorMessage {
    .historyPage(
      .init(
        historyID: snapshotID ?? id, offset: offset, lines: lines, total: total,
        subscriptionID: UUID(), capturedAt: timestamp, truncated: false))
  }

  @Test func pagesMustContinueTheSameSnapshotAndStopAtZero() {
    var gate = MirrorHistoryPageGate()
    let first = gate.accept(page(offset: 1, lines: ["middle", "latest"]))
    #expect(first)
    let changedID = page(offset: 0, lines: ["oldest"], snapshotID: UUID())
    let changedTime = page(offset: 0, lines: ["oldest"], timestamp: 2)
    let invalid = [
      page(offset: 1, lines: ["middle", "latest"]),
      page(offset: 0, total: 4, lines: ["oldest"]),
      page(offset: 0, lines: []), changedID, changedTime,
    ]
    for message in invalid {
      let accepted = gate.accept(message)
      #expect(!accepted)
    }
    let last = gate.accept(page(offset: 0, lines: ["oldest"]))
    #expect(last)
    let extra = gate.accept(page(offset: 0, lines: []))
    #expect(!extra)
  }

  @Test func cumulativeUTF8BytesShareOneBudget() {
    var gate = MirrorHistoryPageGate()
    let nearLimit = String(repeating: "a", count: MirrorHistory.maximumBytes - 3)
    let first = gate.accept(page(offset: 1, total: 2, lines: [nearLimit]))
    #expect(first)
    let exceeded = gate.accept(page(offset: 0, total: 2, lines: ["🌍"]))
    #expect(!exceeded)
    let fits = gate.accept(page(offset: 0, total: 2, lines: ["a"]))
    #expect(fits)
  }

  @Test func timestampMustBeFinite() {
    var gate = MirrorHistoryPageGate()
    for time in [Double.infinity, Double.nan] {
      let invalid = gate.accept(
        page(offset: 0, total: 0, lines: [], timestamp: time))
      #expect(!invalid)
    }
    let valid = gate.accept(page(offset: 0, total: 0, lines: []))
    #expect(valid)
  }
}
