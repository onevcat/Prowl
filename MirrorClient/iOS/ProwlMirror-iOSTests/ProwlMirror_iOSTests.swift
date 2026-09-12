import Foundation
import Testing

@testable import ProwlMirror_iOS

struct ProwlMirror_iOSTests {
  @Test func keychainAddsUpdatesAndRemovesAnIsolatedConnection() throws {
    let account = "test-\(UUID())"
    defer { try? MirrorSavedConnection.remove(account: account) }
    #expect(try MirrorSavedConnection.load(account: account) == nil)
    let first = MirrorSavedConnection(
      address: "127.0.0.1", port: 7880, pairingKey: "",
      credential: .init(hostID: UUID(), deviceID: UUID(), key: try MirrorAuthentication.randomKey())
    )
    try first.save(account: account)
    #expect(try MirrorSavedConnection.load(account: account) == first)
    let second = MirrorSavedConnection(
      address: "::1", port: 7881, pairingKey: "",
      credential: .init(hostID: UUID(), deviceID: UUID(), key: try MirrorAuthentication.randomKey())
    )
    try second.save(account: account)
    #expect(try MirrorSavedConnection.load(account: account) == second)
    try MirrorSavedConnection.remove(account: account)
    #expect(try MirrorSavedConnection.load(account: account) == nil)
  }

  @Test func wirePreservesUnicodeAndRejectsUnboundedFrames() throws {
    let frame: MirrorMessage = .textFrame(
      .init(sequence: 1, text: "思考\n结论", subscriptionID: UUID()))
    let bytes = try MirrorWire.encode(frame)
    #expect(try MirrorWire.decode(bytes.dropFirst(4)).text == frame.text)
    #expect(throws: MirrorProtocolError.self) { try MirrorWire.length(Data([255, 255, 255, 255])) }
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWire.decode(Data(#"{"version":99,"kind":"list"}"#.utf8))
    }
  }
}
