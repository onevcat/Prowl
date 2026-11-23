import CoreImage.CIFilterBuiltins
import SwiftUI

struct MirrorPairingQRCode: View {
  let address: String
  let port: String
  let code: String
  let expires: Date

  var body: some View {
    if let text {
      MirrorQRCodeImage(text: text, size: 180)
        .accessibilityLabel("Pairing QR code")
        .accessibilityIdentifier("remote-mirror-pairing-qr")
    } else {
      Text("Unable to generate the QR code. Use the address and pairing code above.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var text: String? {
    guard let number = UInt16(port),
      let payload = try? MirrorPairingPayload(
        address: address, port: number, code: code, expires: expires)
    else { return nil }
    return try? payload.encoded()
  }

  static func image(for text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
    return CIContext().createCGImage(scaled, from: scaled.extent)
  }
}

/// A QR code on a light quiet zone, so that it scans in either appearance.
struct MirrorQRCodeImage: View {
  let text: String
  let size: CGFloat

  var body: some View {
    if let image = MirrorPairingQRCode.image(for: text) {
      Image(decorative: image, scale: 1)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .padding(12)
        .background(.white)
    } else {
      Text("Unable to generate the QR code.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
