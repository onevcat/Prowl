import Foundation
import Testing

@testable import supacode

struct MirrorPairingPayloadTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func roundTripIPv4AndIPv6() throws {
    for address in ["192.168.1.20", "100.64.0.1", "2001:db8::2"] {
      let payload = try MirrorPairingPayload(
        address: address, port: 7880, code: "ABCD-EFGH", expires: now.addingTimeInterval(60))
      let parsed = try MirrorPairingPayload.parse(payload.encoded(), now: now)
      #expect(parsed == payload)
      #expect(parsed.code == "ABCDEFGH")
    }
  }

  @Test func pastedDetailsReplaceExistingConnectionFieldContents() throws {
    let payload = try MirrorPairingPayload(
      address: "30.172.64.62", port: 5988, code: "ABCD-EFGH", expires: now.addingTimeInterval(60))
    let copied = try payload.encoded()
    for previous in ["old-host.local", "7880", "ZZZZ-YYYY", ""] {
      for input in [copied, previous + copied, copied + previous, " \n" + copied + "\n "] {
        #expect(try MirrorEndpointInput.pastedPairingPayload(input, now: now) == payload)
      }
    }
    #expect(try MirrorEndpointInput.pastedPairingPayload("192.168.0.1", now: now) == nil)
    #expect(try MirrorEndpointInput.pastedPairingPayload("ABCD-EFGH", now: now) == nil)
    #expect(throws: MirrorEndpointInput.Problem.expiredPairingDetails) {
      try MirrorEndpointInput.pastedPairingPayload(copied, now: now.addingTimeInterval(61))
    }
    #expect(throws: MirrorEndpointInput.Problem.invalidPairingDetails) {
      try MirrorEndpointInput.pastedPairingPayload(copied.replacing("5988", with: "0"), now: now)
    }
    #expect(throws: MirrorEndpointInput.Problem.invalidPairingDetails) {
      try MirrorEndpointInput.pastedPairingPayload("{\"type\":\"prowl-mirror-pairing\"", now: now)
    }
  }

  @Test func rejectsExpiredAndMalformedCodes() throws {
    let valid =
      #"{"type":"prowl-mirror-pairing","version":1,"address":"192.168.1.20","port":7880,"#
      + #""code":"ABCDEFGH","expiresAt":1800000060}"#
    #expect(try MirrorPairingPayload.parse(valid, now: now).port == 7880)
    let bad = [
      "https://example.com", "{}", String(repeating: "x", count: 2049),
      valid.replacing("1800000060", with: "1800000000"),
      valid.replacing("\"version\":1", with: "\"version\":2"),
      valid.replacing("7880", with: "0"), valid.replacing("7880", with: "65536"),
      valid.replacing("7880", with: "\"7880\""),
      valid.replacing("ABCDEFGH", with: "invalid"),
      valid.replacing("192.168.1.20", with: "example.com"),
      valid.replacing("192.168.1.20", with: "127.0.0.1"),
      valid.replacing("192.168.1.20", with: "0:0:0:0:0:0:0:1"),
      valid.replacing("192.168.1.20", with: "::ffff:127.0.0.1"),
    ]
    for text in bad {
      #expect(throws: (any Error).self) { try MirrorPairingPayload.parse(text, now: now) }
    }
  }
}
