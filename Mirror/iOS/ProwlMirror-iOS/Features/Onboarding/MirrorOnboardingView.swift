import SwiftUI

/// The first launch: what the app does and how to pair, with the QR code as the main path.
///
/// The layout follows the space the app has, not the device or its orientation (docs-ai 099):
/// wider than tall, the mark and title sit in the leading half and the steps and actions in
/// the trailing half, so on a foldable held like a book the fold runs between them. Taller
/// than wide, everything is one column with the actions at the bottom. Content that does not
/// fit scrolls instead of being cut.
struct MirrorOnboardingView: View {
  let onAdd: () -> Void
  var onTryDemo: (() -> Void)?
  @State private var isWide = false

  var body: some View {
    ViewThatFits(in: .vertical) {
      layout
      ScrollView { layout }
        .scrollBounceBehavior(.basedOnSize)
    }
    .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isWide = $0 }
  }

  @ViewBuilder private var layout: some View {
    if isWide {
      HStack(spacing: 0) {
        intro
          .padding(.horizontal, 24)
          .frame(maxWidth: 380)
          .frame(maxWidth: .infinity)
        VStack(spacing: 0) {
          steps
          actions.padding(.top, 28)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
      }
      .padding(.vertical, 24)
      .frame(maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        Spacer(minLength: 24)
        intro.padding(.horizontal, 32)
        steps
          .padding(.top, 36)
          .padding(.horizontal, 36)
        Spacer(minLength: 28)
        actions
          .padding(.horizontal, 24)
          .padding(.bottom, 24)
      }
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
  }

  private var intro: some View {
    VStack(spacing: 0) {
      Image("ProwlMark")
        .resizable()
        .scaledToFit()
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .accentColor.opacity(0.35), radius: 24, y: 10)
        .accessibilityHidden(true)
      Text("Prowl Mirror")
        .font(.largeTitle.bold())
        .padding(.top, 28)
      Text("Follow the agents on your Mac, answer them, and start new ones — from here.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
  }

  private var steps: some View {
    VStack(alignment: .leading, spacing: 16) {
      step("macbook", "On the Mac, open the Remote Mirror button in the Prowl toolbar.")
      step("qrcode", "Choose Add a Device to show a pairing code.")
      step("iphone", "Scan the code here, or type the address and code.")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var actions: some View {
    VStack(spacing: 0) {
      Button(action: onAdd) {
        Label("Pair with a Mac", systemImage: "qrcode.viewfinder")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .accessibilityIdentifier("add-host")
      .help("Pair with a Mac running Prowl")
      if let onTryDemo {
        // Secondary to pairing: a link, not a second large button.
        Button("Try the Demo", action: onTryDemo)
          .buttonStyle(.borderless)
          .font(.subheadline.weight(.semibold))
          .padding(.top, 14)
          .accessibilityIdentifier("try-demo")
          .help("Explore the app with sample agents, without a Mac")
      }
      Text("New to Prowl? Visit [prowl.cat](https://prowl.cat/)")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        .accessibilityIdentifier("prowl-website")
    }
  }

  private func step(_ symbol: String, _ text: LocalizedStringKey) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
      Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
  }
}
