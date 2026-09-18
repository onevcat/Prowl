import ComposableArchitecture
import SwiftUI

struct GlobalCustomCommandsView: View {
  @Bindable var store: StoreOf<GlobalCustomCommandsFeature>

  var body: some View {
    Form {
      Section {
        CustomCommandsEditor(
          commands: $store.settings.customCommands,
          source: .global,
          keybindingUserOverrides: store.keybindingUserOverrides
        )
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Global Custom Commands")
          Text(
            """
            Global terminal actions available in every repository. \
            Enabled commands appear in the top-right of the window toolbar.
            """
          )
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task { store.send(.task) }
  }
}
