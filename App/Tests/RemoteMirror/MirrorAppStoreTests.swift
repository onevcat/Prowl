import CoreImage
import Foundation
import Testing

@testable import Prowl

@MainActor
struct MirrorAppStoreTests {
  @Test func linkOpensProwlMirrorOnTheAppStore() {
    #expect(MirrorAppStore.url.absoluteString == "https://apps.apple.com/app/id6831901271")
  }

  @Test func qrCodeDecodesToTheAppStoreLink() throws {
    let text = MirrorAppStore.url.absoluteString
    let image = try #require(MirrorPairingQRCode.image(for: text))
    let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext()))
    let feature = try #require(
      detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)
    #expect(feature.messageString == text)
  }
}
