import Foundation
import Testing

@testable import ProwlMirror_iOS

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

  /// The `deflate-v1` vector of `App/Tests/RemoteMirror/MirrorWireCompressionTests.swift`, made by
  /// another zlib: `{"list":{}}` twice, then `{"pong":{}}`, in one stream (docs-ai 097).
  @Test func readsTheCompressedVector() throws {
    let vector: [[UInt8]] = [
      [98, 168, 86, 202, 201, 44, 46, 81, 178, 170, 174, 173, 5, 0, 0, 0, 255, 255],
      [98, 64, 98, 3, 0, 0, 0, 255, 255],
      [2, 178, 11, 242, 243, 210, 193, 108, 0, 0, 0, 0, 255, 255],
    ]
    var inflater: MirrorWireCompression.Inflater?
    let kinds = try vector.map { body in
      try MirrorWire.decode(
        MirrorWireCompression.expand(Data([3] + body), with: &inflater, limit: MirrorWire.maximumPayload)
      ).kind
    }
    #expect(kinds == [.list, .list, .pong])
  }
}
