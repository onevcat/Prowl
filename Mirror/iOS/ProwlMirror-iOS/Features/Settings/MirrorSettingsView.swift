import SwiftUI

/// App settings (docs-ai 098), opened from the Settings menu: paired Hosts, notifications and
/// About. New app-level settings, such as a subscription, add a section here; the menu keeps
/// only the quick actions. The demo shows About only, since its Hosts are not real.
struct MirrorSettingsView: View {
  @Bindable var store: MirrorHostStore
  let onAddHost: () -> Void
  @Environment(\.mirrorDemo) private var demo
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if demo == nil {
          MirrorHostsSection(store: store, onAddHost: onAddHost)
          MirrorNotificationsSection(store: store)
        }
        MirrorAboutSection()
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { dismiss() }
            .accessibilityIdentifier("settings-done")
            .help("Close Settings")
        }
      }
    }
  }
}

/// The version, the website, the privacy policy and the terms.
struct MirrorAboutSection: View {
  static let website = URL(string: "https://prowl.cat/")!
  static let privacyPolicy = URL(string: "https://prowl.cat/privacy")!
  static let terms = URL(string: "https://prowl.cat/terms")!

  var body: some View {
    Section {
      LabeledContent("Version", value: Self.version)
        .accessibilityIdentifier("settings-version")
      Link(destination: Self.website) {
        Label("Prowl Website", systemImage: "safari")
      }
      .accessibilityIdentifier("settings-website")
      Link(destination: Self.privacyPolicy) {
        Label("Privacy Policy", systemImage: "hand.raised")
      }
      .accessibilityIdentifier("settings-privacy")
      Link(destination: Self.terms) {
        Label("Terms of Use", systemImage: "doc.plaintext")
      }
      .accessibilityIdentifier("settings-terms")
    } header: {
      Text("About")
    }
  }

  /// `1.0 (202611230055)`: the marketing version and the build.
  static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "–"
    guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
    return "\(short) (\(build))"
  }
}
