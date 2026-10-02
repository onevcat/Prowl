import Foundation
import MirrorRelayProtocol
import Testing

struct MirrorDisplayFrameTests {
  @Test func stripsOnlyUnsolicitedReportModesFromCanonicalSnapshots() {
    let retained = "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[>11u你好🌍\u{1b}[9;5H"
    let reports = "\u{1b}[?1004h\u{1b}[?2031h\u{1b}[?2048h"
    #expect(MirrorDisplayFrame.passiveSnapshot(Data((reports + retained + reports).utf8)) == Data(retained.utf8))
  }

  @Test func preservesEmptyPartialAndBinaryData() {
    for bytes in [Data(), Data([0, 255, 27]), Data("\u{1b}[?1004".utf8), Data("\u{1b}[?1004l".utf8)] {
      #expect(MirrorDisplayFrame.passiveSnapshot(bytes) == bytes)
    }
  }
}
