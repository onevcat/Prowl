import ComposableArchitecture
import SwiftUI

struct AgentDisplaySettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let effectiveKeybindings: ResolvedKeybindingMap
  let customCommands: [EffectiveCustomCommand]
  let islandHotKeyRegistrationFailure: Keybinding?

  var body: some View {
    Form {
      Section("Active Agents") {
        Toggle(
          "Show Active Agents panel automatically",
          isOn: $store.autoShowActiveAgentsPanel
        )
        .help("Open the Active Agents panel when an agent is detected.")
        Text("Hidden panels reopen as soon as an agent starts or updates.")
          .foregroundStyle(.secondary)
          .font(.callout)
        Toggle(
          "Show terminal titles in agent rows",
          isOn: $store.showActiveAgentTabTitles
        )
        .help("Display each agent's own terminal title in the row and show the branch name on hover.")
        Toggle(
          "Show agent status in Shelf tabs",
          isOn: $store.showActiveAgentStatusInShelf
        )
        .help("Overlay detected agent status on the owning tab icon in Shelf View.")
      }
      AgentIslandSettingsSection(
        store: store,
        effectiveKeybindings: effectiveKeybindings,
        customCommands: customCommands,
        globalHotKeyRegistrationFailure: islandHotKeyRegistrationFailure
      )
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
