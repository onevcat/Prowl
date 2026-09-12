import Foundation
import Testing

@testable import supacode

struct MirrorPairingCodeTests {
  @Test func shortCodeNormalizesAndLegacyKeyIsRejected() throws {
    #expect(try MirrorPairingCode.normalized(" k7mp-3x9r \n") == "K7MP3X9R")
    #expect(try MirrorPairingCode.normalized("K7MP 3X9R") == "K7MP3X9R")
    let legacy = String(repeating: "a", count: 64)
    #expect(throws: MirrorProtocolError.self) { try MirrorPairingCode.normalized(legacy) }
    for invalid in ["", "ABCD", "ABCD-23456", "ABCD-01OI", "ABCD-23é4"] {
      #expect(throws: MirrorProtocolError.self) { try MirrorPairingCode.normalized(invalid) }
    }
    for _ in 0..<20 {
      let code = try MirrorPairingCode.generate()
      #expect(code.count == 9)
      #expect(code[code.index(code.startIndex, offsetBy: 4)] == "-")
      #expect(try MirrorPairingCode.normalized(code).count == 8)
    }
  }

  @Test func connectionAttemptsAreBoundedAndRecoverAfterOneMinute() {
    var limit = MirrorConnectionAttempts()
    for _ in 0..<12 {
      let accepted = limit.allows(source: "a", now: 10)
      #expect(accepted)
      limit.recordFailure(source: "a", now: 10)
    }
    let blocked = limit.allows(source: "a", now: 69.9)
    #expect(!blocked)
    let otherSource = limit.allows(source: "b", now: 69.9)
    #expect(otherSource)
    let recovered = limit.allows(source: "a", now: 70)
    #expect(recovered)
    let invalid = limit.allows(source: "a", now: .nan)
    #expect(!invalid)
  }
}
