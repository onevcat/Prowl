import ComposableArchitecture
import SwiftUI

struct AdvancedSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section("Analytics & Crash Reports") {
        VStack(alignment: .leading) {
          Toggle(
            "Share analytics with Prowl",
            isOn: $store.analyticsEnabled
          )
          .help("Share anonymous usage data with Prowl (requires restart)")
          Text("Anonymous usage data helps improve Prowl.")
            .foregroundStyle(.secondary)
            .interfaceFont(.callout)
          Text("Requires app restart.")
            .foregroundStyle(.secondary)
            .interfaceFont(.callout)
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
            .interfaceFont(.callout)
          Text("Requires app restart.")
            .foregroundStyle(.secondary)
            .interfaceFont(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Section("Terminal Layout") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Restore terminal layout on launch (experimental)",
            isOn: $store.restoreTerminalLayoutOnLaunch
          )
          Text("When enabled, Prowl attempts to restore tabs and splits after restart.")
            .foregroundStyle(.secondary)
            .interfaceFont(.callout)
          Button("Clear saved terminal layout") {
            store.send(.clearTerminalLayoutSnapshotButtonTapped)
          }
          .help("Remove the saved terminal tab and split layout from disk")
          .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
