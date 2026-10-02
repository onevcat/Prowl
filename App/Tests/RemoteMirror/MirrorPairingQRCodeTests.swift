import CoreImage
import Foundation
import Testing

@testable import Prowl

@MainActor
struct MirrorPairingQRCodeTests {
  @Test func generatedImageDecodesToPairingPayload() throws {
    let payload = try MirrorPairingPayload(
      address: "192.168.1.20", port: 7880, code: "ABCD-EFGH", expires: Date().addingTimeInterval(60)
    )
    let text = try payload.encoded()
    let image = try #require(MirrorPairingQRCode.image(for: text))
    let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext()))
    let feature = try #require(
      detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)
    #expect(feature.messageString == text)
    #expect(try MirrorPairingPayload.parse(#require(feature.messageString)) == payload)
  }
}
