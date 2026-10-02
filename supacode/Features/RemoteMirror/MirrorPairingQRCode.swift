import CoreImage.CIFilterBuiltins
import SwiftUI

struct MirrorPairingQRCode: View {
  let address: String
  let port: String
  let code: String
  let expires: Date

  var body: some View {
    if let image = image {
      Image(decorative: image, scale: 1)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(width: 180, height: 180)
        .padding(12)
        // A fixed light quiet zone keeps the code readable in either appearance.
        .background(.white)
        .accessibilityLabel("Pairing QR code")
        .accessibilityIdentifier("remote-mirror-pairing-qr")
    } else {
      Text("Unable to generate the QR code. Use the address and pairing code above.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var image: CGImage? {
    guard let number = UInt16(port),
      let payload = try? MirrorPairingPayload(
        address: address, port: number, code: code, expires: expires),
      let text = try? payload.encoded()
    else { return nil }
    return Self.image(for: text)
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
