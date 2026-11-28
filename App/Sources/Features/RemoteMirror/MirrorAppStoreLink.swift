import SwiftUI

/// Prowl Mirror, the iPhone and iPad client, on the App Store.
enum MirrorAppStore {
  static let url = URL(string: "https://apps.apple.com/app/id6831901271")!
  /// The first release waits for App Store review, so the page behind the QR code is not public yet.
  /// Set to false, or delete the note, when Apple approves the app.
  static let isInReview = true
}

/// Opens a popover with a QR code that takes an iPhone or iPad to Prowl Mirror on the App Store.
/// The caller sets the title and the button style.
struct MirrorAppStoreButton: View {
  let title: LocalizedStringKey
  @State private var isPresented = false

  var body: some View {
    Button(title) { isPresented = true }
      .help("Show a QR code that opens Prowl Mirror on the App Store on an iPhone or iPad")
      .accessibilityIdentifier("remote-mirror-get-app")
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        MirrorAppStoreCard()
      }
  }
}

private struct MirrorAppStoreCard: View {
  var body: some View {
    VStack(spacing: 12) {
      Text("Get Prowl Mirror").font(.headline)
      if MirrorAppStore.isInReview {
        Label(
          "Prowl Mirror is still in App Store review. This code and link work as soon as Apple approves the app.",
          systemImage: "hourglass"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .accessibilityIdentifier("remote-mirror-app-store-review-note")
      }
      Text("Scan this code with the Camera app on your iPhone or iPad to open Prowl Mirror on the App Store.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      MirrorQRCodeImage(text: MirrorAppStore.url.absoluteString, size: 150)
        .accessibilityLabel("App Store QR code for Prowl Mirror")
        .accessibilityIdentifier("remote-mirror-app-store-qr")
      Link(destination: MirrorAppStore.url) {
        Text(verbatim: "apps.apple.com/app/id6831901271")
      }
      .help("Open the Prowl Mirror page on the App Store in your browser")
      Text("Prowl Mirror needs iOS 26 or later.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(width: 280)
    .accessibilityIdentifier("remote-mirror-app-store-card")
  }
}
