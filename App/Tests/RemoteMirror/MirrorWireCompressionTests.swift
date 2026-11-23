import Foundation
import Testing

@testable import Prowl

struct MirrorWireCompressionTests {
  /// Three type-3 payload bodies of one stream, made by another zlib (Python, raw DEFLATE,
  /// level 6, sync flush): `{"list":{}}` twice, then `{"pong":{}}`. Every client must read
  /// them, whatever bytes its own deflater writes.
  static let vector: [[UInt8]] = [
    [98, 168, 86, 202, 201, 44, 46, 81, 178, 170, 174, 173, 5, 0, 0, 0, 255, 255],
    [98, 64, 98, 3, 0, 0, 0, 255, 255],
    [2, 178, 11, 242, 243, 210, 193, 108, 0, 0, 0, 0, 255, 255],
  ]

  @Test func readsTheVectorOfAnotherZlib() throws {
    var inflater: MirrorWireCompression.Inflater?
    let kinds = try Self.vector.map { body in
      let plain = try MirrorWireCompression.expand(Data([3] + body), with: &inflater, limit: MirrorWire.maximumPayload)
      return try MirrorWire.decode(plain).kind
    }
    #expect(kinds == [.list, .list, .pong])
  }

  @Test func aStreamRoundTripsEveryPayloadTypeAndShrinksRepeats() throws {
    let deflater = try MirrorWireCompression.Deflater()
    var inflater: MirrorWireCompression.Inflater?
    let panes = MirrorMessage.panes(
      .init(
        panes: (0..<4).map { index in
          MirrorPaneDescriptor(
            id: UUID(), title: "Claude Code · feature-\(index)", directory: "/Users/me/Projects/Prowl", busy: false,
            projectName: "Prowl", agent: "claude")
        },
        capabilities: ["text-v1", "conversation-v1", MirrorWireCompression.capability], hostRunID: UUID()))
    let text = MirrorMessage.textFrame(
      .init(
        columns: 80, rows: 24, truncated: false, sequence: 7, text: String(repeating: "ls -la\n", count: 200),
        subscriptionID: UUID()))
    var sizes: [Int] = []
    for message in [panes, panes, panes, text, .pong] {
      let plain = try MirrorWire.payload(message)
      let compressed = try deflater.compress(plain)
      #expect(compressed.first == MirrorWireCompression.payloadType)
      sizes.append(compressed.count)
      let expanded = try MirrorWireCompression.expand(compressed, with: &inflater, limit: MirrorWire.maximumPayload)
      #expect(expanded == plain)
    }
    // A list the stream has seen costs a few dozen bytes instead of the whole list.
    let plainList = try MirrorWire.payload(panes).count
    #expect(sizes[0] < plainList)
    #expect(sizes[1] < 64 && sizes[2] < 64, "repeated list sizes: \(sizes)")
  }

  @Test func plainPayloadsPassThroughWithoutAStream() throws {
    var inflater: MirrorWireCompression.Inflater?
    let plain = try MirrorWire.payload(.pong)
    #expect(try MirrorWireCompression.expand(plain, with: &inflater, limit: MirrorWire.maximumPayload) == plain)
    #expect(inflater == nil)
  }

  @Test func rejectsCorruptNestedAndOversizedPayloads() throws {
    var inflater: MirrorWireCompression.Inflater?
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWireCompression.expand(Data([3, 0xFF, 0x00, 0x13]), with: &inflater, limit: MirrorWire.maximumPayload)
    }
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWireCompression.expand(Data([3]), with: &inflater, limit: MirrorWire.maximumPayload)
    }

    let deflater = try MirrorWireCompression.Deflater()
    var fresh: MirrorWireCompression.Inflater?
    let nested = try deflater.compress(Data([3, 1, 2, 3]))
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWireCompression.expand(nested, with: &fresh, limit: MirrorWire.maximumPayload)
    }

    // One megabyte of zeros compresses to about a kilobyte; the limit stops it, not the size.
    let bomb = try MirrorWireCompression.Deflater().compress(Data([0]) + Data(count: 1_024 * 1_024))
    var bounded: MirrorWireCompression.Inflater?
    #expect(bomb.count < 4_096)
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWireCompression.expand(bomb, with: &bounded, limit: 64 * 1_024)
    }
  }
}
