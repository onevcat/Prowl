import ComposableArchitecture
import SwiftUI

struct AdvancedSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section("Analytics & Crash Reports") {
        Toggle(isOn: $store.analyticsEnabled) {
          Text("Share analytics with Prowl")
          Text("Anonymous usage data helps improve Prowl.")
          Text("Requires app restart.")
        }
        .help("Share anonymous usage data with Prowl (requires restart)")

        Toggle(isOn: $store.crashReportsEnabled) {
          Text("Share crash reports with Prowl")
          Text("Anonymous crash reports help improve stability.")
          Text("Requires app restart.")
        }
        .help("Share anonymous crash reports with Prowl (requires restart)")
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
