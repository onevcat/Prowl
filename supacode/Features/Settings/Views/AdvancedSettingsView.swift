import ComposableArchitecture
import SwiftUI

struct AdvancedSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section("Advanced") {
          VStack(alignment: .leading) {
            Toggle(
              "Share analytics with Prowl",
              isOn: $store.analyticsEnabled
            )
            .help("Share anonymous usage data with Prowl (requires restart)")
            Text("Anonymous usage data helps improve Prowl.")
              .foregroundStyle(.secondary)
              .font(.callout)
            Text("Requires app restart.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading) {
            Toggle(
              "Share crash reports with Prowl",
              isOn: $store.crashReportsEnabled
            )
            .help("Share anonymous crash reports with Prowl (requires restart)")
            Text("Anonymous crash reports help improve stability.")
              .foregroundStyle(.secondary)
              .font(.callout)
            Text("Requires app restart.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
