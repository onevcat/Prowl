import Foundation
import MirrorRelayProtocol
import Testing

struct MirrorRelayPacketTests {
  @Test func heartbeatHasAnEmptyPayload() throws {
    #expect(try MirrorRelayPacket(kind: .ping, payload: Data()).encoded() == Data([5, 0, 0, 0, 0]))
    #expect(try MirrorRelayPacket.header(Data([6, 0, 0, 0, 0])).kind == .pong)
    #expect(throws: MirrorRelayPacket.Failure.self) {
      try MirrorRelayPacket.header(Data([5, 0, 0, 0, 1]))
    }
  }
  @Test func frameUsesBinaryHeaderAndPreservesTerminalBytes() throws {
    let payload = MirrorRelayPacket.sequenceBytes(258) + Data([0x1B, 0x5B, 0x30, 0x6D, 0xFF])
    let packet = MirrorRelayPacket(kind: .frame, payload: payload)
    let encoded = try packet.encoded()
    #expect(Array(encoded.prefix(5)) == [2, 0, 0, 0, 13])
    let header = try MirrorRelayPacket.header(Data(encoded.prefix(5)))
    #expect(header.kind == .frame)
    #expect(header.length == payload.count)
    #expect(Data(encoded.dropFirst(5)) == payload)
    #expect(try MirrorRelayPacket.sequence(Data(payload.prefix(8))) == 258)
  }

  @Test(arguments: [
    Data(), Data([2, 0, 0, 0]), Data([99, 0, 0, 0, 1]),
    Data([2, 0, 0, 0, 0]), Data([2, 0xFF, 0xFF, 0xFF, 0xFF]),
  ])
  func malformedHeaderIsRejected(_ bytes: Data) {
    #expect(throws: MirrorRelayPacket.Failure.self) { try MirrorRelayPacket.header(bytes) }
  }

  @Test func emptyOrOversizePayloadIsRejected() {
    for count in [0, MirrorRelayPacket.maximumPayload + 1] {
      #expect(throws: MirrorRelayPacket.Failure.self) {
        try MirrorRelayPacket(kind: .input, payload: Data(count: count)).encoded()
      }
    }
  }

  @Test func sequenceRequiresExactlyEightBytes() {
    #expect(throws: MirrorRelayPacket.Failure.self) {
      try MirrorRelayPacket.sequence(Data([1]))
    }
  }
}
