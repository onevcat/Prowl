import ComposableArchitecture
import SwiftUI

struct UpdatesSettingsView: View {
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  let updatesStore: StoreOf<UpdatesFeature>

  var body: some View {
    Form {
      Section {
        Toggle(
          "Check for updates automatically",
          isOn: $settingsStore.updatesAutomaticallyCheckForUpdates
        )
      } header: {
        Text("Automatic Updates")
      } footer: {
        Text(
          "When a new version is available, a small badge appears next to the notifications bell. "
            + "Click it to review, install, and choose future background downloads."
        )
        .interfaceFont(.callout)
        .foregroundStyle(.secondary)
      }

      Section {
        Button("Check for Updates Now") {
          updatesStore.send(.checkForUpdates)
        }
        .help("Check for updates now")
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
