import Foundation
import Testing

@testable import supacode

struct MirrorWireVectorTests {
  @Test func textVectorAndMalformedPayloads() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var expected: [UInt8] = [0, 0, 0, 35, 2]
    expected += Array(repeating: 0, count: 15)
    expected += [1]
    expected += Array(repeating: 0, count: 7)
    expected += [1, 0, 0, 0, 80, 0, 0, 0, 24, 1, 65]
    let message = MirrorMessage.textFrame(
      .init(
        columns: 80, rows: 24, truncated: true,
        sequence: 1, text: "A", subscriptionID: id))
    #expect(try Array(MirrorWire.encode(message)) == expected)
    guard case .textFrame(let decoded) = try MirrorWire.decode(Data(expected.dropFirst(4))) else {
      Issue.record("Expected text frame")
      return
    }
    #expect(decoded.columns == 80 && decoded.rows == 24 && decoded.truncated)
    #expect(decoded.text == "A" && decoded.subscriptionID == id)
    var invalidUTF8 = expected
    invalidUTF8[invalidUTF8.count - 1] = 255
    #expect(throws: (any Error).self) { try MirrorWire.decode(Data(invalidUTF8.dropFirst(4))) }
    for invalid in [
      Data([255]), Data([0]) + Data(#"{"subscribe":{"_0":{}}}"#.utf8), Data([2, 0]),
      Data(#"{"version":2,"kind":"list"}"#.utf8),
    ] {
      #expect(throws: (any Error).self) { try MirrorWire.decode(invalid) }
    }
  }
}
