import Foundation
import Testing

@testable import supacode

struct MirrorProtocolTests {
  @Test func frameRoundTripKeepsControlBytesAndUnicode() throws {
    let frame = MirrorFrame(columns: 81, rows: 25, bytes: Data("\u{1b}[2J思考中\r结论\u{1b}[H".utf8))
    let wire = try MirrorWire.encode(MirrorMessage(kind: .frame, frame: frame, sequence: 1))
    #expect(try MirrorWire.length(wire.prefix(4)) == wire.count - 4)
    #expect(try MirrorWire.decode(wire.dropFirst(4)).frame == frame)
  }

  @Test func invalidLengthsAndVersionsAreRejectedBeforeDispatch() {
    #expect(throws: MirrorProtocolError.self) { try MirrorWire.length(Data([0, 0, 0])) }
    #expect(throws: MirrorProtocolError.self) { try MirrorWire.length(Data([0, 0, 0, 0])) }
    #expect(throws: MirrorProtocolError.self) { try MirrorWire.length(Data([255, 255, 255, 255])) }
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWire.decode(Data(#"{"version":2,"kind":"list"}"#.utf8))
    }
  }

  @Test func slowConsumerHasOneOutstandingFrameAndReceivesLatestState() throws {
    var gate = MirrorFrameGate()
    let first = MirrorFrame(columns: 80, rows: 24, bytes: Data("thinking".utf8))
    let cleared = MirrorFrame(columns: 80, rows: 24, bytes: Data())
    #expect(gate.offer(first) == 1)
    #expect(gate.offer(cleared) == nil)
    #expect(throws: MirrorProtocolError.self) { try gate.acknowledge(2) }
    try gate.acknowledge(1)
    #expect(gate.offer(first) == nil)
    #expect(gate.offer(cleared) == 2)
    try gate.acknowledge(2)
    let resized = MirrorFrame(columns: 100, rows: 24, bytes: Data())
    #expect(gate.offer(resized) == 3)
  }

  @Test func historyPagesAreStableAndBounded() throws {
    let history = MirrorHistory(text: (0..<451).map(String.init).joined(separator: "\n"))
    let latest = try history.page(before: history.lines.count)
    #expect(latest.start == 251)
    #expect(latest.lines.first == "251")
    #expect(latest.lines.last == "450")
    let older = try history.page(before: latest.start)
    #expect(older.start == 51)
    #expect(older.lines.last == "250")
    #expect(try history.page(before: 0).lines.isEmpty)
    #expect(throws: MirrorProtocolError.self) { try history.page(before: -1) }
    #expect(throws: MirrorProtocolError.self) { try history.page(before: 452) }
    #expect(MirrorHistory(text: "changed").id != history.id)
  }

  @Test @MainActor func malformedPairingKeysFailBeforeOpeningASocket() {
    for key in ["", "1234", String(repeating: "g", count: 64)] {
      #expect(throws: MirrorProtocolError.self) { try MirrorConnection.parameters(pairingKey: key) }
    }
  }
}
