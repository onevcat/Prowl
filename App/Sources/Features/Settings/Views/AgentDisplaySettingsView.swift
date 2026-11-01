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
        Toggle(isOn: $store.autoShowActiveAgentsPanel) {
          Text("Show Active Agents panel automatically")
          Text("Hidden panels reopen as soon as an agent starts or updates.")
        }
        .help("Open the Active Agents panel when an agent is detected.")
        Toggle(
          "Show terminal titles in agent rows",
          isOn: $store.showActiveAgentTabTitles
        )
        .help("Display each agent's own terminal title in the row and show the branch name on hover.")
        Toggle(
          "Show agent names in agent rows",
          isOn: $store.showActiveAgentNames
        )
        .help("Display the agent name before the repository name. When off, the name shows on hover.")
        Toggle(
          "Show agent status in Shelf tabs",
          isOn: $store.showActiveAgentStatusInShelf
        )
        .help("Overlay detected agent status on the owning tab icon in Shelf View.")
      }
      Section("SSH Sessions") {
        Toggle(
          isOn: Binding(
            get: { store.remoteAgentDetection.showsEnabled },
            set: { store.send(.setRemoteAgentDetection($0 ? .enabled : .disabled)) })
        ) {
          Text("Detect agents in SSH sessions")
          Text(
            """
            When a pane runs ssh, Prowl opens its own connection to the same host and runs a \
            read-only check to find agents. It installs nothing on the host.
            """)
        }
        .help("Let Prowl open its own SSH connection to show the agents that run on the host.")
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
